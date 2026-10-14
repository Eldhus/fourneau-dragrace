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
	Fourneau string
	// Roux is roux's checkout, ready: its platform's host in
	// platform/targets, its tools in zig-out/bin.
	Roux string
	Used ToolchainUsed
}

// ToolchainUsed is the record of what a build was built with,
// out/toolchain.json, which race.tar.gz carries and a race posts
// (versionRows): Zig and roc at roux's pins; Go, Rust, axum and tokio at
// the competitors' (competitorVersions).
type ToolchainUsed struct {
	Zig   string `json:"zig"`
	Roc   string `json:"roc"`
	Go    string `json:"go"`
	Rust  string `json:"rust"`
	Axum  string `json:"axum"`
	Tokio string `json:"tokio"`
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
		return pins, fmt.Errorf("roux's pins (roux checked out beside this repository): %w", err)
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
	cache, err := cacheDir()
	if err != nil {
		return Toolchain{}, err
	}
	var tools Toolchain
	tools.Fourneau = checkoutPath(root, "fourneau")
	tools.Roux = checkoutPath(root, "roux")
	for _, checkout := range []string{tools.Fourneau, tools.Roux} {
		if _, err := os.Stat(filepath.Join(checkout, "build.zig")); err != nil {
			return tools, fmt.Errorf("no checkout at %s (fourneau and roux go beside this repository)", checkout)
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
	if err := installRocMusl(ctx, cache, pins.RocMusl, tools.Roux); err != nil {
		return tools, err
	}
	tools.Used = ToolchainUsed{Zig: pins.Zig.Version, Roc: pins.Roc.Version}
	if err := competitorVersions(ctx, root, &tools.Used); err != nil {
		return tools, err
	}
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
	log.Printf("toolchain: zig %s, roc %s, go %s, rust %s", tools.Used.Zig, tools.Used.Roc,
		tools.Used.Go, tools.Used.Rust)
	return tools, nil
}

// competitorVersions asks the Go and Rust tools, in the competitors'
// directories, for their pins: Go's from competitors/go's go.mod (its
// toolchain line), Rust's as rustup picks it from
// competitors/axum/rust-toolchain.toml, and axum's and tokio's as
// Cargo.lock resolves them. Asked on every build, a competitor from the
// store included: its key covers the files they come from.
func competitorVersions(ctx context.Context, root string, used *ToolchainUsed) error {
	goMod, err := output(ctx, filepath.Join(root, "competitors", "go"), "go", "mod", "edit",
		"-json")
	if err != nil {
		return err
	}
	var module struct{ Go, Toolchain string }
	if err := json.Unmarshal([]byte(goMod), &module); err != nil {
		return fmt.Errorf("go mod edit: %w", err)
	}
	used.Go = module.Go
	if module.Toolchain != "" {
		used.Go = strings.TrimPrefix(module.Toolchain, "go")
	}
	axum := filepath.Join(root, "competitors", "axum")
	// rustc -vV is `key: value` lines, release among them (rustc's own
	// documented format, which cargo reads too).
	rustc, err := output(ctx, axum, "rustc", "-vV")
	if err != nil {
		return err
	}
	for _, line := range strings.Split(rustc, "\n") {
		if value, found := strings.CutPrefix(line, "release: "); found {
			used.Rust = value
		}
	}
	metadata, err := output(ctx, axum, "cargo", "metadata", "--format-version", "1", "--locked")
	if err != nil {
		return err
	}
	var cargo struct {
		Packages []struct{ ID, Name, Version string }
		Resolve  struct {
			Root  string
			Nodes []struct {
				ID   string
				Deps []struct{ Pkg string }
			}
		}
	}
	if err := json.Unmarshal([]byte(metadata), &cargo); err != nil {
		return fmt.Errorf("cargo metadata: %w", err)
	}
	// The root package's own dependencies, as resolved.
	direct := map[string]bool{}
	for _, node := range cargo.Resolve.Nodes {
		if node.ID == cargo.Resolve.Root {
			for _, dep := range node.Deps {
				direct[dep.Pkg] = true
			}
		}
	}
	for _, pkg := range cargo.Packages {
		if direct[pkg.ID] && pkg.Name == "axum" {
			used.Axum = pkg.Version
		}
		if direct[pkg.ID] && pkg.Name == "tokio" {
			used.Tokio = pkg.Version
		}
	}
	if used.Go == "" || used.Rust == "" || used.Axum == "" || used.Tokio == "" {
		return fmt.Errorf("competitors' versions: go %q, rust %q, axum %q, tokio %q", used.Go,
			used.Rust, used.Axum, used.Tokio)
	}
	return nil
}

// fetchOha is the loader at race.json's pin, fetched and verified once.
func fetchOha(ctx context.Context, pin Download) (string, error) {
	cache, err := cacheDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(cache, "oha-"+pin.Version)
	if err := fetchFile(ctx, pin.URL, pin.SHA256, path); err != nil {
		return "", err
	}
	return path, os.Chmod(path, 0o755)
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
