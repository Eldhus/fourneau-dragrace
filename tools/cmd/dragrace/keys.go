package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// A competitor is built only when its key is new: the key is a hash of everything its binary is built from, and
// the binary is kept in a store under it, so equal keys are equal builds
// and a binary is never taken for another's. A wrong key would race a
// stale binary and publish a wrong number, so the key takes more than it
// strictly needs rather than less.

// competitorKeyRecipe changes whenever what a key covers, or how a
// competitor is built (buildCompetitor), changes: no binary stored under
// an older recipe is ever taken for a newer one.
const competitorKeyRecipe = "competitor-key 2"

// storeKeep is how many binaries the store keeps for each competitor, the
// newest used first.
const storeKeep = 3

// competitorKey hashes, in order: the recipe; the competitor's directory
// and workloads/ as the checkout has them (every file git tracks or would
// track, uncommitted changes included); versions.json; each of its
// `inputs`, the trees its build reads by path outside its directory
// (fourneau-zig: fourneau, and roux's vendored SQLite); the machine image;
// and the tools its steps name: {roux} the roux and fourneau checkouts
// (rouxIdentity) and roc, {roc} roc, {zig} Zig.
func competitorKey(ctx context.Context, root string, tools Toolchain, competitor Competitor) (string,
	error) {
	hash := sha256.New()
	part := func(name, value string) {
		fmt.Fprintf(hash, "%s\x00%d\x00%s\x00", name, len(value), value)
	}
	part("recipe", competitorKeyRecipe)
	part("name", competitor.Name)
	for _, sub := range []string{filepath.Join("competitors", competitor.Name), "workloads",
		"versions.json"} {
		tree, err := treeHash(ctx, root, sub)
		if err != nil {
			return "", err
		}
		part(sub, tree)
	}
	for _, input := range competitor.Inputs {
		tree, err := treeHash(ctx, filepath.Join(root, input), ".")
		if err != nil {
			return "", fmt.Errorf("%s's input %s: %w", competitor.Name, input, err)
		}
		part("input "+input, tree)
	}
	part("image", machineImage(ctx))
	uses := competitor.uses()
	if uses["roux"] {
		roux, err := rouxIdentity(ctx, tools)
		if err != nil {
			return "", err
		}
		part("roux", roux)
	}
	if uses["roux"] || uses["roc"] {
		part("roc", tools.Used.Roc)
	}
	if uses["zig"] {
		part("zig", tools.Used.Zig)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// uses is which of the toolchain's placeholders the competitor's build
// steps name.
func (competitor Competitor) uses() map[string]bool {
	uses := map[string]bool{}
	for _, step := range competitor.Build {
		texts := append([]string{step.Cwd}, step.Argv...)
		for _, value := range step.Env {
			texts = append(texts, value)
		}
		for _, name := range []string{"roux", "roc", "zig"} {
			for _, text := range texts {
				if strings.Contains(text, "{"+name+"}") {
					uses[name] = true
				}
			}
		}
	}
	return uses
}

// treeHash hashes the files under sub that git tracks or would track
// (`git ls-files --cached --others --exclude-standard`): each one's path,
// whether it is executable, and its contents (a symbolic link's target).
// A deleted file still listed as tracked counts as gone.
func treeHash(ctx context.Context, dir, sub string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", "ls-files", "--cached", "--others", "--exclude-standard",
		"-z", "--", sub)
	cmd.Dir = dir
	cmd.Stderr = os.Stderr
	listing, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git ls-files %s in %s: %w (a build is of a git checkout)", sub, dir, err)
	}
	paths := strings.Split(strings.TrimRight(string(listing), "\x00"), "\x00")
	sort.Strings(paths)
	paths = slices.Compact(paths) // a file both tracked and modified is listed once
	hash := sha256.New()
	for _, path := range paths {
		if path == "" {
			continue
		}
		full := filepath.Join(dir, path)
		info, err := os.Lstat(full)
		if os.IsNotExist(err) {
			fmt.Fprintf(hash, "%s\x00gone\x00", path)
			continue
		}
		if err != nil {
			return "", err
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(full)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(hash, "%s\x00link\x00%s\x00", path, target)
		case info.Mode().IsRegular():
			fmt.Fprintf(hash, "%s\x00%t\x00%d\x00", path, info.Mode()&0o111 != 0, info.Size())
			file, err := os.Open(full)
			if err != nil {
				return "", err
			}
			_, copyErr := io.Copy(hash, file)
			file.Close()
			if copyErr != nil {
				return "", copyErr
			}
		}
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// rouxIdentity is what roux's platform and tools are built from: roux's
// and fourneau's trees (roux's holds its toolchain.json, so Zig's and
// roc's versions too).
func rouxIdentity(ctx context.Context, tools Toolchain) (string, error) {
	roux, err := treeHash(ctx, tools.Roux, ".")
	if err != nil {
		return "", err
	}
	fourneau, err := treeHash(ctx, tools.Fourneau, ".")
	if err != nil {
		return "", err
	}
	return roux + " " + fourneau, nil
}

// rouxKeyRecipe is to roux's key what competitorKeyRecipe is to a
// competitor's.
const rouxKeyRecipe = "roux-key 1"

// rouxBuilt are the files `zig build platform` and `zig build tools` make
// in roux's checkout, which the roux competitor and the site use.
var rouxBuilt = []string{"platform/targets/x64musl/libhost.a", "zig-out/bin/roux",
	"zig-out/bin/roux-db", "zig-out/bin/roux-load"}

// readyRoux puts roux's platform and tools in its checkout: from the
// store under their key (the recipe, roux's and fourneau's trees, the
// machine), else built there and stored. On a developer's machine it saves
// little (Zig's own cache is warm); on GitHub's runner it saves compiling
// roux for every build of the site.
func readyRoux(ctx context.Context, tools Toolchain) error {
	identity, err := rouxIdentity(ctx, tools)
	if err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(rouxKeyRecipe + "\x00" + identity + "\x00" + machineImage(ctx)))
	key := hex.EncodeToString(sum[:])
	store, err := storeDir()
	if err != nil {
		return err
	}
	stored := filepath.Join(store, rouxStoreName+"-"+key)
	if _, err := os.Stat(filepath.Join(stored, "done")); err == nil {
		for _, path := range rouxBuilt {
			if err := copyFile(filepath.Join(stored, path), filepath.Join(tools.Roux, path)); err != nil {
				return err
			}
		}
		now := time.Now()
		log.Printf("roux: from the store, key %s", key[:12])
		return os.Chtimes(stored, now, now)
	}
	for _, step := range []string{"platform", "tools"} {
		if err := run(ctx, tools.Roux, nil, tools.Zig, "build", step); err != nil {
			return err
		}
	}
	os.RemoveAll(stored)
	for _, path := range rouxBuilt {
		if err := copyFile(filepath.Join(tools.Roux, path), filepath.Join(stored, path)); err != nil {
			return err
		}
	}
	// Written last: a store entry cut short has no `done` and is built again.
	if err := os.WriteFile(filepath.Join(stored, "done"), nil, 0o644); err != nil {
		return err
	}
	log.Printf("roux: built and stored, key %s", key[:12])
	return pruneStore(store, rouxStoreName, os.RemoveAll)
}

// rouxStoreName names roux's entries in the store, apart from the roux
// competitor's (roux-KEY).
const rouxStoreName = "roux-platform"

// machineImage names what a build links against besides its pins (the C
// compiler and libc a Rust or Go build may use): GitHub's runner image by
// its version, or this machine's compiler.
func machineImage(ctx context.Context) string {
	if image := os.Getenv("ImageOS"); image != "" {
		return "runner " + image + " " + os.Getenv("ImageVersion")
	}
	host, _ := os.Hostname()
	compiler, _ := exec.CommandContext(ctx, "cc", "--version").Output()
	return "machine " + host + " " + string(bytes.TrimSpace(compiler))
}

// storeDir is the store of built competitors: STORE/NAME-KEY.
func storeDir() (string, error) {
	cache, err := cacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cache, "competitors"), nil
}

// fromStore copies the competitor's binary for key into out/bin, if the
// store has it, and marks it used.
func fromStore(root, name, key string) (bool, error) {
	store, err := storeDir()
	if err != nil {
		return false, err
	}
	stored := filepath.Join(store, name+"-"+key)
	if _, err := os.Stat(stored); err != nil {
		return false, nil
	}
	if err := copyFile(stored, filepath.Join(binDir(root), name)); err != nil {
		return false, err
	}
	now := time.Now()
	return true, os.Chtimes(stored, now, now)
}

// toStore keeps the competitor's binary just built under key, then drops
// all but the newest storeKeep of that competitor's.
func toStore(root, name, key string) error {
	store, err := storeDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(store, 0o755); err != nil {
		return err
	}
	stored := filepath.Join(store, name+"-"+key)
	if err := copyFile(filepath.Join(binDir(root), name), stored); err != nil {
		return err
	}
	return pruneStore(store, name, os.Remove)
}

// pruneStore keeps the newest used storeKeep of name's entries (NAME-KEY,
// the key 64 hex characters) and removes the rest.
func pruneStore(store, name string, remove func(string) error) error {
	entries, err := filepath.Glob(filepath.Join(store, name+"-*"))
	if err != nil {
		return err
	}
	type kept struct {
		path string
		used time.Time
	}
	var all []kept
	for _, path := range entries {
		if len(filepath.Base(path)) != len(name)+1+64 {
			continue // another name's entry, or one being written (.partial)
		}
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		all = append(all, kept{path, info.ModTime()})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].used.After(all[j].used) })
	for _, old := range all[min(len(all), storeKeep):] {
		log.Printf("store: dropping %s", filepath.Base(old.path))
		if err := remove(old.path); err != nil {
			return err
		}
	}
	return nil
}

// raceKeyRecipe is to the race key what competitorKeyRecipe is to a
// competitor's.
const raceKeyRecipe = "race-key 1"

// raceKey is a hash of what a race races: each competitor's key,
// race.json and workloads/. A check races only when it is not the last
// race's (racer.tonight). The tool's own code is not in it: a change to
// the tool alone is raced with the next change that is, or when the owner
// asks (`site race-now`).
func raceKey(ctx context.Context, root string, competitors map[string]string) (string, error) {
	hash := sha256.New()
	fmt.Fprintf(hash, "%s\x00", raceKeyRecipe)
	names := make([]string, 0, len(competitors))
	for name := range competitors {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintf(hash, "%s\x00%s\x00", name, competitors[name])
	}
	for _, sub := range []string{"race.json", "workloads"} {
		tree, err := treeHash(ctx, root, sub)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(hash, "%s\x00%s\x00", sub, tree)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// competitorKeysPath is out/competitors.json, each competitor's key as it
// was built, which the bundle records.
func competitorKeysPath(root string) string { return filepath.Join(outDir(root), "competitors.json") }

func writeCompetitorKeys(root string, keys map[string]string) error {
	encoded, err := json.MarshalIndent(keys, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(competitorKeysPath(root), encoded, 0o644)
}
