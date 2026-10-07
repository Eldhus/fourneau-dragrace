package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// `dragrace site dev`: the site rebuilt and reloaded as it is edited, for
// work on the UI (the owner, 2026-10-07). Races and deploys keep `site
// build`'s optimized build: LLVM takes 80 to 90 s, Roc's dev backend 2.
//
// One watcher (inotify) over site/, site/db and site/static, and one
// serial pipeline, so a build never reads a half-written generated module:
// a changed template is regenerated (rocstache-gen), changed queries
// regenerate the db modules (roux-db), and when any Roc source then
// differs from the last build the app is built with `--opt=dev` and
// restarted. A changed static file restarts the app without a build
// (roux reads static files at startup). Changes are
// decided by content (sha256), not by modification time or by which event
// came, so a save that changes nothing, and the generators' own writes,
// cost nothing.
//
// The browser talks to a proxy, never to the app: the proxy injects a
// script into each HTML page that listens on /_dev/events and reloads on a
// new build, shows a failed build's output over the page, and holds
// requests while the app restarts. The test suite (`roc test`) runs after
// each build, beside it, and a failure shows as a banner.
//
// The testing ground for a build server in roux: kept to what a port to
// Zig needs (a bounded file set, inotify, child processes, a proxy).

const (
	devFilesMax         = 512                   // files watched; more is a mistake
	devFileBytesMax     = 4 << 20               // per file hashed
	devPageBytesMax     = 8 << 20               // an HTML page the proxy rewrites
	devClientsMax       = 64                    // browsers listening for reloads
	devSettle           = 25 * time.Millisecond // a save's burst of events
	devBuildTimeout     = 2 * time.Minute
	devStopTimeout      = 3 * time.Second
	devReadyTimeout     = 10 * time.Second
	devHoldTimeout      = 30 * time.Second // a request waits this long for the app
	devOutputBytesMax   = 64 << 10         // of a failed step's output, shown
	devInotifyMask      = syscall.IN_CLOSE_WRITE | syscall.IN_MOVED_TO | syscall.IN_CREATE | syscall.IN_DELETE | syscall.IN_MOVED_FROM
	devInotifyBufferLen = 64 << 10
)

func siteDevCommand(ctx context.Context, root string, args []string) error {
	flags := newFlags("site dev")
	port := flags.Int("port", 8090, "the proxy's port: open http://127.0.0.1:PORT/")
	appPort := flags.Int("app-port", 8091, "the app's own port, behind the proxy")
	flags.Parse(args)
	if *port == *appPort {
		return fmt.Errorf("-port and -app-port must differ")
	}
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	// The generators, built once: a change to them is a change to roux.
	for _, step := range []string{"platform", "tools"} {
		if err := run(ctx, tools.Roux, nil, tools.Zig, "build", step); err != nil {
			return err
		}
	}
	dev := newDevServer(root, tools, *appPort)
	defer dev.app.stop()
	watcher, err := newDevWatcher(dev.dirs())
	if err != nil {
		return err
	}
	defer watcher.close()
	server := &http.Server{Addr: fmt.Sprintf("127.0.0.1:%d", *port), Handler: dev.handler()}
	go func() {
		<-ctx.Done()
		server.Close()
	}()
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("dev: %v", err)
		}
	}()
	log.Printf("dev: http://127.0.0.1:%d/ (the app on %d); editing site/ rebuilds", *port, *appPort)
	dev.step(ctx, true)
	return dev.loop(ctx, watcher)
}

// devServer is the pipeline's state: what the last pass saw and built, the
// app, and the browsers listening.
type devServer struct {
	root, site string
	tools      Toolchain
	binary     string
	app        *devApp
	seen       map[string][32]byte // every input's content at the last pass
	built      [32]byte            // the Roc sources' digest at the last good build
	events     *devEvents
}

func newDevServer(root string, tools Toolchain, appPort int) *devServer {
	site := filepath.Join(root, "site")
	binary := filepath.Join(outDir(root), "dev", "dragrace-site")
	return &devServer{root: root, site: site, tools: tools, binary: binary,
		app:    &devApp{binary: binary, dir: site, port: appPort, ready: newDevGate()},
		seen:   map[string][32]byte{},
		events: &devEvents{clients: map[chan devEvent]struct{}{}}}
}

func (dev *devServer) dirs() []string {
	return []string{dev.site, filepath.Join(dev.site, "db"), filepath.Join(dev.site, "static")}
}

// loop runs a pass after each burst of events, until stopped.
func (dev *devServer) loop(ctx context.Context, watcher *devWatcher) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-watcher.errors:
			return err
		case <-watcher.events:
		}
		// The rest of the burst: an editor's save is several events.
		settle := time.NewTimer(devSettle)
	drain:
		for {
			select {
			case <-watcher.events:
				settle.Reset(devSettle)
			case <-settle.C:
				break drain
			case <-ctx.Done():
				return nil
			}
		}
		dev.step(ctx, false)
	}
}

// step is one pass: regenerate what changed, build when Roc changed,
// restart, tell the browsers. `first` builds whatever the digest says.
func (dev *devServer) step(ctx context.Context, first bool) {
	started := time.Now()
	inputs, err := dev.scan()
	if err != nil {
		dev.fail("scan", err.Error())
		return
	}
	changed := dev.changed(inputs)
	if !first && len(changed) == 0 {
		return
	}
	if out, err := dev.generate(ctx, changed, first); err != nil {
		dev.fail("generate", out)
		return
	}
	// The generators wrote Roc: read again, so their output counts as
	// seen and the next pass does not take it for an edit.
	inputs, err = dev.scan()
	if err != nil {
		dev.fail("scan", err.Error())
		return
	}
	dev.changed(inputs)
	digest := rocDigest(inputs)
	if digest == dev.built && dev.app.running() {
		// roux loads static files once, at startup (fourneau's site.zig
		// keeps them, gzipped, in memory): a changed one needs the app
		// restarted, though not rebuilt (found 2026-10-07: the old CSS
		// served after a reload).
		if out, err := dev.app.restart(ctx); err != nil {
			dev.fail("start", out+err.Error())
			return
		}
		log.Printf("dev: %s; restarted (%d ms)", strings.Join(changed, " "), time.Since(started).Milliseconds())
		dev.events.send(devEvent{kind: "reload"})
		return
	}
	if out, err := dev.build(ctx); err != nil {
		dev.fail("build", out)
		return
	}
	built := time.Now()
	if out, err := dev.app.restart(ctx); err != nil {
		dev.fail("start", out+err.Error())
		return
	}
	dev.built = digest
	what := strings.Join(changed, " ")
	if first {
		what = fmt.Sprintf("%d files", len(inputs))
	}
	log.Printf("dev: %s; built %d ms, up %d ms", what,
		built.Sub(started).Milliseconds(), time.Since(built).Milliseconds())
	dev.events.send(devEvent{kind: "reload"})
	go dev.test(ctx, dev.events.current())
}

func (dev *devServer) fail(what, output string) {
	log.Printf("dev: %s failed:\n%s", what, output)
	dev.events.send(devEvent{kind: "failed", text: what + " failed\n\n" + output})
}

// scan reads every input: templates, Roc, queries and static files.
func (dev *devServer) scan() (map[string][32]byte, error) {
	inputs := map[string][32]byte{}
	for _, dir := range dev.dirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() || !devInput(dir == filepath.Join(dev.site, "static"), entry.Name()) {
				continue
			}
			if len(inputs) == devFilesMax {
				return nil, fmt.Errorf("more than %d files under %s", devFilesMax, dev.site)
			}
			path := filepath.Join(dir, entry.Name())
			digest, err := devHash(path)
			if err != nil {
				return nil, err
			}
			relative, _ := filepath.Rel(dev.site, path)
			inputs[relative] = digest
		}
	}
	return inputs, nil
}

// devInput is whether a file is a source: every static file; elsewhere
// templates, Roc and SQL (not site.db, not an editor's swap file).
func devInput(static bool, name string) bool {
	if strings.HasPrefix(name, ".") || strings.HasSuffix(name, "~") {
		return false
	}
	if static {
		return true
	}
	switch filepath.Ext(name) {
	case ".rocstache", ".roc", ".sql":
		return true
	}
	return false
}

func devHash(path string) ([32]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return [32]byte{}, err
	}
	defer file.Close()
	hash := sha256.New()
	read, err := io.Copy(hash, io.LimitReader(file, devFileBytesMax+1))
	if err != nil {
		return [32]byte{}, err
	}
	if read > devFileBytesMax {
		return [32]byte{}, fmt.Errorf("%s: over %d bytes", path, devFileBytesMax)
	}
	var digest [32]byte
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

// changed is the inputs that differ from the last pass, sorted, and makes
// them the last pass.
func (dev *devServer) changed(inputs map[string][32]byte) []string {
	var changed []string
	for path, digest := range inputs {
		if seen, ok := dev.seen[path]; !ok || seen != digest {
			changed = append(changed, path)
		}
	}
	for path := range dev.seen {
		if _, ok := inputs[path]; !ok {
			changed = append(changed, path)
		}
	}
	sort.Strings(changed)
	dev.seen = inputs
	return changed
}

// rocDigest is the Roc sources' content, together: what a build reads.
func rocDigest(inputs map[string][32]byte) [32]byte {
	var paths []string
	for path := range inputs {
		if filepath.Ext(path) == ".roc" {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	hash := sha256.New()
	for _, path := range paths {
		digest := inputs[path]
		hash.Write([]byte(path))
		hash.Write(digest[:])
	}
	var digest [32]byte
	copy(digest[:], hash.Sum(nil))
	return digest
}

// generate runs the generators for what changed (all of them on the first
// pass): rocstache-gen per template, roux-db once for any query.
func (dev *devServer) generate(ctx context.Context, changed []string, first bool) (string, error) {
	bin := filepath.Join(dev.tools.Roux, "zig-out", "bin")
	queries := first
	for _, path := range changed {
		switch {
		case filepath.Ext(path) == ".sql":
			queries = true
		case filepath.Ext(path) == ".rocstache" && filepath.Dir(path) == ".":
			if _, err := os.Stat(filepath.Join(dev.site, path)); err != nil {
				continue // deleted: its module stays until the Roc says otherwise
			}
			module := strings.TrimSuffix(path, ".rocstache") + ".roc"
			out, err := devRun(ctx, dev.site, filepath.Join(bin, "rocstache-gen"), "-o", module, path)
			if err != nil {
				return out, err
			}
		}
	}
	if first {
		templates, err := filepath.Glob(filepath.Join(dev.site, "*.rocstache"))
		if err != nil {
			return "", err
		}
		for _, template := range templates {
			name := filepath.Base(template)
			module := strings.TrimSuffix(name, ".rocstache") + ".roc"
			if out, err := devRun(ctx, dev.site, filepath.Join(bin, "rocstache-gen"), "-o", module, name); err != nil {
				return out, err
			}
		}
	}
	if queries {
		return devRun(ctx, dev.site, filepath.Join(bin, "roux-db"), "gen", "db")
	}
	return "", nil
}

// build compiles with the dev backend into a new file, then moves it over
// the old one: the running app keeps its binary until it is stopped.
func (dev *devServer) build(ctx context.Context) (string, error) {
	if err := os.MkdirAll(filepath.Dir(dev.binary), 0o755); err != nil {
		return "", err
	}
	next := dev.binary + ".next"
	ctx, cancel := context.WithTimeout(ctx, devBuildTimeout)
	defer cancel()
	out, err := devRun(ctx, dev.site, dev.tools.Roc, "build", "main.roc", "--opt=dev", "--output="+next)
	if err != nil {
		return out, err
	}
	return out, os.Rename(next, dev.binary)
}

// test runs the expects of the build of `generation`, and shows the result
// while that build is still the newest. (It reads the sources as they are
// now; an edit since starts a newer generation, whose result counts.)
func (dev *devServer) test(ctx context.Context, generation uint64) {
	out, err := devRun(ctx, dev.site, dev.tools.Roc, "test", "main.roc")
	if ctx.Err() != nil || generation != dev.events.current() {
		return
	}
	if err != nil {
		log.Printf("dev: roc test failed:\n%s", out)
		dev.events.send(devEvent{kind: "tests", text: out})
		return
	}
	dev.events.send(devEvent{kind: "tests"})
}

// devRun runs a step and keeps its output, bounded, for the browser.
func devRun(ctx context.Context, dir string, argv ...string) (string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err := cmd.Run()
	text := output.String()
	if len(text) > devOutputBytesMax {
		text = text[:devOutputBytesMax] + "\n[cut]"
	}
	if err != nil {
		return text, fmt.Errorf("%s: %w", filepath.Base(argv[0]), err)
	}
	return text, nil
}

// devApp is the site's process, behind the proxy.
type devApp struct {
	binary, dir string
	port        int
	ready       *devGate
	mutex       sync.Mutex
	cmd         *exec.Cmd
	exited      chan struct{}
	output      *devTail
}

func (app *devApp) running() bool {
	app.mutex.Lock()
	defer app.mutex.Unlock()
	if app.cmd == nil {
		return false
	}
	select {
	case <-app.exited:
		return false
	default:
		return true
	}
}

// restart stops the app (it holds site.db's lock and its port), starts the
// new build and waits until it answers; requests wait meanwhile.
func (app *devApp) restart(ctx context.Context) (string, error) {
	app.ready.close()
	app.stop()
	app.mutex.Lock()
	cmd := exec.Command(app.binary)
	cmd.Dir = app.dir
	cmd.Env = append(os.Environ(), "ROUX_PORT="+strconv.Itoa(app.port))
	tail := &devTail{}
	cmd.Stdout = io.MultiWriter(os.Stderr, tail)
	cmd.Stderr = cmd.Stdout
	exited := make(chan struct{})
	err := cmd.Start()
	if err == nil {
		app.cmd, app.exited, app.output = cmd, exited, tail
		go func() {
			cmd.Wait()
			close(exited)
		}()
	}
	app.mutex.Unlock()
	if err != nil {
		return "", err
	}
	address := fmt.Sprintf("127.0.0.1:%d", app.port)
	deadline := time.Now().Add(devReadyTimeout)
	for time.Now().Before(deadline) {
		select {
		case <-exited:
			return tail.String(), fmt.Errorf("the app exited")
		case <-ctx.Done():
			return "", ctx.Err()
		default:
		}
		if connection, err := net.DialTimeout("tcp", address, 100*time.Millisecond); err == nil {
			connection.Close()
			app.ready.open()
			return "", nil
		}
		time.Sleep(5 * time.Millisecond)
	}
	return tail.String(), fmt.Errorf("the app did not answer on %s in %s", address, devReadyTimeout)
}

// stop ends the app: SIGTERM, then SIGKILL after devStopTimeout.
func (app *devApp) stop() {
	app.mutex.Lock()
	defer app.mutex.Unlock()
	if app.cmd == nil {
		return
	}
	app.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-app.exited:
	case <-time.After(devStopTimeout):
		app.cmd.Process.Kill()
		<-app.exited
	}
	app.cmd = nil
}

// devTail keeps the end of the app's output, to show why it would not start.
type devTail struct {
	mutex sync.Mutex
	data  []byte
}

func (tail *devTail) Write(p []byte) (int, error) {
	tail.mutex.Lock()
	defer tail.mutex.Unlock()
	tail.data = append(tail.data, p...)
	if len(tail.data) > devOutputBytesMax {
		tail.data = tail.data[len(tail.data)-devOutputBytesMax:]
	}
	return len(p), nil
}

func (tail *devTail) String() string {
	tail.mutex.Lock()
	defer tail.mutex.Unlock()
	return string(tail.data)
}

// devGate holds requests while the app restarts: open, a wait returns at
// once; closed, it waits for the next open.
type devGate struct {
	mutex  sync.Mutex
	opened chan struct{}
}

func newDevGate() *devGate { return &devGate{opened: make(chan struct{})} }

func (gate *devGate) open() {
	gate.mutex.Lock()
	defer gate.mutex.Unlock()
	select {
	case <-gate.opened:
	default:
		close(gate.opened)
	}
}

func (gate *devGate) close() {
	gate.mutex.Lock()
	defer gate.mutex.Unlock()
	select {
	case <-gate.opened:
		gate.opened = make(chan struct{})
	default:
	}
}

func (gate *devGate) wait(ctx context.Context) error {
	gate.mutex.Lock()
	opened := gate.opened
	gate.mutex.Unlock()
	select {
	case <-opened:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// devEvent is what the browsers are told: "reload", "failed" (with the
// output), or "tests" (with the failures; none, passed).
type devEvent struct {
	kind, text string
}

// devEvents is the browsers listening, and the newest build's state, sent
// to each as it connects: a page that missed a reload, or loaded under a
// failed build, learns of it.
type devEvents struct {
	mutex      sync.Mutex
	clients    map[chan devEvent]struct{}
	generation uint64
	failed     string
	tests      string
}

func (events *devEvents) send(event devEvent) {
	events.mutex.Lock()
	defer events.mutex.Unlock()
	switch event.kind {
	case "reload":
		events.generation++
		events.failed = ""
	case "failed":
		events.failed = event.text
	case "tests":
		events.tests = event.text
	}
	for client := range events.clients {
		select {
		case client <- event:
		default: // a browser that is not reading misses it; it reconnects
		}
	}
}

func (events *devEvents) subscribe() (chan devEvent, uint64, devEvent, devEvent, bool) {
	events.mutex.Lock()
	defer events.mutex.Unlock()
	if len(events.clients) == devClientsMax {
		return nil, 0, devEvent{}, devEvent{}, false
	}
	client := make(chan devEvent, 8)
	events.clients[client] = struct{}{}
	return client, events.generation, devEvent{kind: "failed", text: events.failed},
		devEvent{kind: "tests", text: events.tests}, true
}

func (events *devEvents) unsubscribe(client chan devEvent) {
	events.mutex.Lock()
	defer events.mutex.Unlock()
	delete(events.clients, client)
}

func (events *devEvents) current() uint64 {
	events.mutex.Lock()
	defer events.mutex.Unlock()
	return events.generation
}

// handler is the proxy: /_dev/events, else the app, its pages with the
// script added.
func (dev *devServer) handler() http.Handler {
	target := &url.URL{Scheme: "http", Host: fmt.Sprintf("127.0.0.1:%d", dev.app.port)}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1 // event streams pass as they come
	direct := proxy.Director
	proxy.Director = func(request *http.Request) {
		direct(request)
		// Pages uncompressed, so the script can go in.
		request.Header.Del("Accept-Encoding")
	}
	proxy.ModifyResponse = func(response *http.Response) error {
		return devInject(response, dev.events.current())
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		page := devPage("the app is down", err.Error(), dev.events.current())
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusBadGateway)
		w.Write(page)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/_dev/events" {
			dev.serveEvents(w, r)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), devHoldTimeout)
		defer cancel()
		if err := dev.app.ready.wait(ctx); err != nil {
			proxy.ErrorHandler(w, r, fmt.Errorf("no app after %s: see the build's output", devHoldTimeout))
			return
		}
		proxy.ServeHTTP(w, r)
	})
}

func (dev *devServer) serveEvents(w http.ResponseWriter, r *http.Request) {
	client, generation, failed, tests, ok := dev.events.subscribe()
	if !ok {
		http.Error(w, "too many browsers listening", http.StatusServiceUnavailable)
		return
	}
	defer dev.events.unsubscribe(client)
	flusher, _ := w.(http.Flusher)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	write := func(event devEvent) {
		data := strings.ReplaceAll(event.text, "\n", "\ndata: ")
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event.kind, data)
		if flusher != nil {
			flusher.Flush()
		}
	}
	write(devEvent{kind: "generation", text: strconv.FormatUint(generation, 10)})
	write(failed)
	write(tests)
	for {
		select {
		case <-r.Context().Done():
			return
		case event := <-client:
			write(event)
		}
	}
}

// devInject adds the script to an HTML page, uncompressed and of bounded
// size; anything else passes untouched.
func devInject(response *http.Response, generation uint64) error {
	kind := response.Header.Get("Content-Type")
	if !strings.HasPrefix(kind, "text/html") || response.Header.Get("Content-Encoding") != "" {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, devPageBytesMax+1))
	response.Body.Close()
	if err != nil {
		return err
	}
	if len(body) > devPageBytesMax {
		return fmt.Errorf("a page over %d bytes", devPageBytesMax)
	}
	script := []byte(devScript(generation))
	if at := bytes.LastIndex(body, []byte("</body>")); at >= 0 {
		body = append(body[:at:at], append(script, body[at:]...)...)
	} else {
		body = append(body, script...)
	}
	response.Body = io.NopCloser(bytes.NewReader(body))
	response.ContentLength = int64(len(body))
	response.Header.Set("Content-Length", strconv.Itoa(len(body)))
	response.Header.Del("ETag")
	response.Header.Set("Cache-Control", "no-store")
	return nil
}

// devPage is the proxy's own page, when the app cannot answer.
func devPage(title, text string, generation uint64) []byte {
	return []byte("<!doctype html><meta charset=utf-8><title>" + html.EscapeString(title) +
		"</title><body><pre>" + html.EscapeString(text) + "</pre>" + devScript(generation) + "</body>")
}

// devScript listens for builds: a newer generation reloads the page, a
// failure lays its output over the page, a test failure is a banner. The
// generation is the build this page came from.
func devScript(generation uint64) string {
	return `<script>(() => {
  const loaded = ` + strconv.FormatUint(generation, 10) + `;
  const panel = (id, css) => {
    let el = document.getElementById(id);
    if (!el) { el = document.createElement("pre"); el.id = id; el.style.cssText = css; document.body.append(el); }
    return el;
  };
  const show = (id, css, text) => {
    if (text) { panel(id, css).textContent = text; } else { document.getElementById(id)?.remove(); }
  };
  const base = "position:fixed;left:0;right:0;z-index:2147483647;margin:0;padding:12px 16px;" +
    "font:12px/1.4 monospace;white-space:pre-wrap;color:#fff;";
  const events = new EventSource("/_dev/events");
  events.addEventListener("generation", (e) => { if (Number(e.data) !== loaded) location.reload(); });
  events.addEventListener("reload", () => location.reload());
  events.addEventListener("failed", (e) => show("dev-failed", base + "top:0;bottom:0;overflow:auto;background:rgba(40,0,0,.94);", e.data));
  events.addEventListener("tests", (e) => show("dev-tests", base + "bottom:0;max-height:40vh;overflow:auto;background:rgba(90,40,0,.94);", e.data ? "roc test failed\n\n" + e.data : ""));
})();</script>`
}

// devWatcher is inotify over a few directories, not recursive: an event
// says only that something there changed; the pass reads what.
type devWatcher struct {
	descriptor int
	events     chan struct{}
	errors     chan error
}

func newDevWatcher(dirs []string) (*devWatcher, error) {
	descriptor, err := syscall.InotifyInit1(syscall.IN_CLOEXEC)
	if err != nil {
		return nil, fmt.Errorf("inotify: %w", err)
	}
	for _, dir := range dirs {
		if _, err := syscall.InotifyAddWatch(descriptor, dir, devInotifyMask); err != nil {
			syscall.Close(descriptor)
			return nil, fmt.Errorf("inotify %s: %w", dir, err)
		}
	}
	watcher := &devWatcher{descriptor: descriptor, events: make(chan struct{}, 1), errors: make(chan error, 1)}
	go watcher.read()
	return watcher, nil
}

func (watcher *devWatcher) read() {
	buffer := make([]byte, devInotifyBufferLen)
	for {
		n, err := syscall.Read(watcher.descriptor, buffer)
		if err == syscall.EINTR {
			continue
		}
		if err != nil || n <= 0 {
			if !errors.Is(err, syscall.EBADF) {
				watcher.errors <- fmt.Errorf("inotify read: %v", err)
			}
			return
		}
		select {
		case watcher.events <- struct{}{}:
		default: // a pass is already due; it reads every file
		}
	}
}

func (watcher *devWatcher) close() { syscall.Close(watcher.descriptor) }
