package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// Toolchain is where the pinned tools are, once fetched and verified.
// Go and Rust come from their own pinning (go.mod, rust-toolchain.toml);
// Zig and roc from roux's (RouxPins).
type Toolchain struct {
	Zig      string
	Roc      string
	Oha      string
	Fourneau string
	// Roux is roux's checkout, ready: its platform's host in
	// platform/targets, its tools in zig-out/bin.
	Roux string
	Used ToolchainUsed
}

// ToolchainUsed is the record of what a build was built with,
// out/toolchain.json, which race.tar.gz carries and a race posts.
type ToolchainUsed struct {
	Zig string `json:"zig"`
	Roc string `json:"roc"`
}

func toolchainRecord(root string) string { return filepath.Join(outDir(root), "toolchain.json") }

// RouxPins are roux's toolchain.json: the Zig and roc roux is built with,
// which the drag race builds with too (one pin per tool, in the
// repository that owns it), and musl's two files.
type RouxPins struct {
	Zig     Download `json:"zig"`
	Roc     Download `json:"roc"`
	RocMusl RocMusl  `json:"roc_musl"`
}

func rouxPinsOf(dir string) (RouxPins, error) {
	var pins RouxPins
	path := filepath.Join(dir, "toolchain.json")
	if err := readJSON(path, &pins); err != nil {
		return pins, fmt.Errorf("roux's pins (README.md, Use it): %w", err)
	}
	if pins.Zig.SHA256 == "" || pins.Roc.SHA256 == "" {
		return pins, fmt.Errorf("%s: no zig or roc pin", path)
	}
	return pins, nil
}

// cacheDir holds downloads: $DRAGRACE_CACHE, else ~/.cache/fourneau-dragrace.
func cacheDir() (string, error) {
	if dir := os.Getenv("DRAGRACE_CACHE"); dir != "" {
		return dir, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "fourneau-dragrace"), nil
}

func loadToolchain(ctx context.Context, root string) (Toolchain, error) {
	versions, err := loadVersions(root)
	if err != nil {
		return Toolchain{}, err
	}
	cache, err := cacheDir()
	if err != nil {
		return Toolchain{}, err
	}
	var tools Toolchain
	tools.Fourneau = checkoutPath(root, versions.Fourneau)
	tools.Roux = checkoutPath(root, versions.Roux)
	for _, checkout := range []string{tools.Fourneau, tools.Roux} {
		if _, err := os.Stat(filepath.Join(checkout, "build.zig")); err != nil {
			return tools, fmt.Errorf("no checkout at %s (README.md, Use it)", checkout)
		}
	}
	pins, err := rouxPinsOf(tools.Roux)
	if err != nil {
		return tools, err
	}
	zigDir, err := fetchArchive(ctx, cache, "zig-"+pins.Zig.Version, pins.Zig)
	if err != nil {
		return tools, err
	}
	tools.Zig = filepath.Join(zigDir, "zig")
	rocDir, err := fetchArchive(ctx, cache, "roc-"+pins.Roc.Version, pins.Roc)
	if err != nil {
		return tools, err
	}
	tools.Roc = filepath.Join(rocDir, "roc")
	tools.Oha = filepath.Join(cache, "oha-"+versions.Oha.Version)
	if err := fetchFile(ctx, versions.Oha.URL, versions.Oha.SHA256, tools.Oha); err != nil {
		return tools, err
	}
	if err := os.Chmod(tools.Oha, 0o755); err != nil {
		return tools, err
	}
	if err := installRocMusl(ctx, cache, pins.RocMusl, tools.Roux); err != nil {
		return tools, err
	}
	tools.Used = ToolchainUsed{Zig: pins.Zig.Version, Roc: pins.Roc.Version}
	// roux's platform and tools: from the store when their key is there,
	// else built and stored (keys.go), so a build of the site alone does
	// not compile roux.
	if err := readyRoux(ctx, tools); err != nil {
		return tools, err
	}
	record, err := json.Marshal(tools.Used)
	if err != nil {
		return tools, err
	}
	if err := os.MkdirAll(outDir(root), 0o755); err != nil {
		return tools, err
	}
	if err := os.WriteFile(toolchainRecord(root), record, 0o644); err != nil {
		return tools, err
	}
	log.Printf("toolchain: zig %s, roc %s, oha %s", pins.Zig.Version, pins.Roc.Version,
		versions.Oha.Version)
	return tools, nil
}

// fetchArchive downloads and verifies an archive and unpacks it once; the
// directory holding the single top-level directory's contents is returned.
func fetchArchive(ctx context.Context, cache, name string, pin Download) (string, error) {
	dir := filepath.Join(cache, name)
	if _, err := os.Stat(filepath.Join(dir, ".verified")); err == nil {
		return dir, nil
	}
	archive := filepath.Join(cache, filepath.Base(pin.URL))
	if err := fetchFile(ctx, pin.URL, pin.SHA256, archive); err != nil {
		return "", err
	}
	if err := os.RemoveAll(dir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	if err := run(ctx, dir, nil, "tar", "-xf", archive, "--strip-components=1"); err != nil {
		return "", err
	}
	return dir, os.WriteFile(filepath.Join(dir, ".verified"), []byte(pin.SHA256+"\n"), 0o644)
}

// fetchFile downloads url to path unless a file with the expected sha256
// is already there; a mismatch is an error, never a silent re-download.
func fetchFile(ctx context.Context, url, want, path string) error {
	if got, err := fileSHA256(path); err == nil && got == want {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	log.Printf("fetch %s", url)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", url, response.Status)
	}
	partial := path + ".partial"
	file, err := os.Create(partial)
	if err != nil {
		return err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(file, hash), response.Body)
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return fmt.Errorf("%s: %v %v", url, copyErr, closeErr)
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != want {
		os.Remove(partial)
		return fmt.Errorf("%s: sha256 %s, pinned %s", url, got, want)
	}
	return os.Rename(partial, path)
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// installRocMusl puts musl's crt1.o and libc.a where `roc build` looks for
// them in the roux checkout, from Roc's source at the pinned commit,
// each file checked against its own pin (GitHub's archives are not
// byte-stable, so the archive itself is not pinned).
func installRocMusl(ctx context.Context, cache string, musl RocMusl, roux string) error {
	targets := filepath.Join(roux, "platform", "targets", "x64musl")
	missing := false
	for path, want := range musl.Files {
		got, err := fileSHA256(filepath.Join(targets, filepath.Base(path)))
		if err != nil || got != want {
			missing = true
		}
	}
	if !missing {
		return nil
	}
	source := filepath.Join(cache, "roc-source-"+musl.Commit)
	if err := os.MkdirAll(source, 0o755); err != nil {
		return err
	}
	archive := filepath.Join(cache, "roc-"+musl.Commit+".tar.gz")
	if err := fetchUnpinned(ctx, musl.URL, archive); err != nil {
		return err
	}
	argv := []string{"tar", "-xzf", archive, "--strip-components=1", "--wildcards"}
	for path := range musl.Files {
		argv = append(argv, "*/"+path)
	}
	if err := run(ctx, source, nil, argv...); err != nil {
		return err
	}
	if err := os.MkdirAll(targets, 0o755); err != nil {
		return err
	}
	for path, want := range musl.Files {
		got, err := fileSHA256(filepath.Join(source, path))
		if err != nil || got != want {
			return fmt.Errorf("roc source %s: %s sha256 %s, pinned %s", musl.Commit, path, got, want)
		}
		bytes, err := os.ReadFile(filepath.Join(source, path))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(targets, filepath.Base(path)), bytes, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// fetchUnpinned downloads a file whose contents are checked afterwards.
func fetchUnpinned(ctx context.Context, url, path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", url, response.Status)
	}
	file, err := os.Create(path + ".partial")
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(file, response.Body)
	if err := file.Close(); err != nil || copyErr != nil {
		return fmt.Errorf("%s: %v %v", url, copyErr, err)
	}
	return os.Rename(path+".partial", path)
}

// expand fills a step's placeholders.
func expand(text string, values map[string]string) string {
	for key, value := range values {
		text = strings.ReplaceAll(text, "{"+key+"}", value)
	}
	return text
}
