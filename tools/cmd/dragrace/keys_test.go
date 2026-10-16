package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// keyRepo is a checkout as competitorKey reads one: two competitors,
// workloads/, race.json, and target/ ignored; and a fourneau checkout.
func keyRepo(t *testing.T) (root string, tools Toolchain) {
	t.Helper()
	t.Setenv("ImageOS", "test")
	t.Setenv("ImageVersion", "1")
	base := t.TempDir()
	root = filepath.Join(base, "fourneau-dragrace")
	tools = Toolchain{Fourneau: filepath.Join(base, "fourneau"), Roux: filepath.Join(base, "roux"),
		Used: ToolchainUsed{Zig: "0.17.0", Roc: "nightly-1"}}
	files := map[string]string{
		filepath.Join(root, ".gitignore"):                        "target/\n",
		filepath.Join(root, "competitors/plain/main.go"):         "package main\n",
		filepath.Join(root, "competitors/plain/competitor.json"): "{}\n",
		filepath.Join(root, "competitors/other/main.go"):         "package main\n",
		filepath.Join(root, "workloads/menu.html"):               "<p>menu</p>\n",
		filepath.Join(root, "race.json"):                         "{}\n",
		filepath.Join(tools.Fourneau, "src/fourneau.zig"):        "pub const x = 1;\n",
		filepath.Join(tools.Roux, "host/host.zig"):               "pub const y = 1;\n",
	}
	for path, text := range files {
		writeFile(t, path, text)
	}
	for _, dir := range []string{root, tools.Fourneau, tools.Roux} {
		for _, argv := range [][]string{{"init", "-q"}, {"add", "-A"},
			{"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "t"}} {
			cmd := exec.Command("git", argv...)
			cmd.Dir = dir
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v %s", argv, err, out)
			}
		}
	}
	return root, tools
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCompetitorKey(t *testing.T) {
	root, tools := keyRepo(t)
	ctx := context.Background()
	plain := Competitor{Name: "plain", Build: CompetitorBuild{Argv: []string{"go", "build"}}}
	zig := Competitor{Name: "plain", Inputs: []string{"../fourneau/src"},
		Build: CompetitorBuild{Argv: []string{"zig", "build"}}}
	roux := Competitor{Name: "plain", Build: CompetitorBuild{Argv: []string{"roux", "build"}}}
	key := func(competitor Competitor) string {
		t.Helper()
		got, err := competitorKey(ctx, root, tools, competitor)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	base, baseZig, baseRoux := key(plain), key(zig), key(roux)
	if base == baseZig || base == baseRoux || baseZig == baseRoux {
		t.Fatal("the pinned tools a competitor's build runs are not in its key")
	}
	if key(plain) != base {
		t.Fatal("a key is not stable")
	}
	changes := []struct {
		name  string
		path  string
		text  string
		moves [3]bool // plain, zig, roux
	}{
		{"its own file, uncommitted", "competitors/plain/main.go", "package main // x\n", [3]bool{true, true, true}},
		{"a new file of its own", "competitors/plain/new.go", "package main\n", [3]bool{true, true, true}},
		{"an ignored file", "competitors/plain/target/out.o", "binary", [3]bool{false, false, false}},
		{"another competitor's file", "competitors/other/main.go", "package other\n", [3]bool{false, false, false}},
		{"a workload", "workloads/menu.html", "<p>other</p>\n", [3]bool{true, true, true}},
		// oha's pin: the race key's (TestRaceKey), no competitor's.
		{"race.json", "race.json", `{"oha": {"version": "2"}}`, [3]bool{false, false, false}},
		// roux's platform compiles all of fourneau, so its key takes all.
		{"an input", "../fourneau/src/fourneau.zig", "pub const x = 2;\n", [3]bool{false, true, true}},
		{"beside an input", "../fourneau/README.md", "fourneau\n", [3]bool{false, false, true}},
		{"roux", "../roux/host/host.zig", "pub const y = 2;\n", [3]bool{false, false, true}},
	}
	for _, change := range changes {
		path := filepath.Join(root, change.path)
		old, readErr := os.ReadFile(path)
		writeFile(t, path, change.text)
		got := [3]bool{key(plain) != base, key(zig) != baseZig, key(roux) != baseRoux}
		if got != change.moves {
			t.Errorf("%s: keys moved %v (plain, zig, roux), want %v", change.name, got, change.moves)
		}
		if readErr == nil {
			writeFile(t, path, string(old))
		} else if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if key(plain) != base || key(zig) != baseZig || key(roux) != baseRoux {
			t.Fatalf("%s: undone, the keys did not come back", change.name)
		}
	}
	t.Setenv("ImageVersion", "2")
	if key(plain) == base {
		t.Error("the runner image is not in the key")
	}
}

// The race key moves with a competitor's key, race.json and a workload,
// and not with the site or the tool.
func TestRaceKey(t *testing.T) {
	root, _ := keyRepo(t)
	ctx := context.Background()
	keys := map[string]string{"plain": "k1", "other": "k2"}
	key := func(keys map[string]string) string {
		t.Helper()
		got, err := raceKey(ctx, root, keys)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	base := key(keys)
	if key(map[string]string{"plain": "k1", "other": "k3"}) == base {
		t.Error("a competitor's key does not move the race key")
	}
	for path, moves := range map[string]bool{"race.json": true, "workloads/menu.html": true,
		"site/Page.rocstache": false, "tools/racer.go": false} {
		full := filepath.Join(root, path)
		old, readErr := os.ReadFile(full)
		writeFile(t, full, "changed\n")
		if got := key(keys) != base; got != moves {
			t.Errorf("%s: the race key moved %v, want %v", path, got, moves)
		}
		if readErr == nil {
			writeFile(t, full, string(old))
		} else if err := os.Remove(full); err != nil {
			t.Fatal(err)
		}
	}
}

func TestStore(t *testing.T) {
	t.Setenv("DRAGRACE_CACHE", t.TempDir())
	root := t.TempDir()
	binary := filepath.Join(binDir(root), "plain")
	key := func(n int) string { return fmt.Sprintf("%064d", n) }
	if found, err := fromStore(root, "plain", key(1)); err != nil || found {
		t.Fatalf("an empty store gave %v, %v", found, err)
	}
	store, err := storeDir()
	if err != nil {
		t.Fatal(err)
	}
	// Each stored a second after the last, so the oldest is plain: the
	// store drops by when an entry was last used.
	start := time.Now().Add(-time.Hour)
	for n := 1; n <= storeKeep; n++ {
		writeFile(t, binary, fmt.Sprintf("build %d", n))
		if err := toStore(root, "plain", key(n)); err != nil {
			t.Fatal(err)
		}
		at := start.Add(time.Duration(n) * time.Second)
		if err := os.Chtimes(filepath.Join(store, "plain-"+key(n)), at, at); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, binary, fmt.Sprintf("build %d", storeKeep+1))
	if err := toStore(root, "plain", key(storeKeep+1)); err != nil {
		t.Fatal(err)
	}
	if found, _ := fromStore(root, "plain", key(1)); found {
		t.Errorf("the store kept more than %d", storeKeep)
	}
	found, err := fromStore(root, "plain", key(2))
	if err != nil || !found {
		t.Fatalf("the store lost key 2: %v, %v", found, err)
	}
	if got, _ := os.ReadFile(binary); string(got) != "build 2" {
		t.Errorf("the store gave %q for key 2", got)
	}
}

// The harness key moves with tools/ and race.json, not with the site.
func TestHarnessKey(t *testing.T) {
	root, _ := keyRepo(t)
	writeFile(t, filepath.Join(root, "tools/cmd/dragrace/main.go"), "package main\n")
	key := func() string {
		t.Helper()
		got, err := harnessKey(context.Background(), root)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	first := key()
	writeFile(t, filepath.Join(root, "site/main.roc"), "app []\n")
	if key() != first {
		t.Error("the site moved the harness key")
	}
	writeFile(t, filepath.Join(root, "tools/cmd/dragrace/main.go"), "package main // changed\n")
	second := key()
	if second == first {
		t.Error("tools/ did not move the harness key")
	}
	writeFile(t, filepath.Join(root, "race.json"), "{\"rounds\": 1}\n")
	if key() == second {
		t.Error("race.json did not move the harness key")
	}
}

// A smoke race races every competitor on a new harness or with no release
// before, else only those whose key moved: none for the site alone.
func TestSmokeSet(t *testing.T) {
	names := []string{"go", "axum", "roux"}
	keys := map[string]string{"go": "g1", "axum": "a2", "roux": "r1"}
	last := &BuildInfo{HarnessKey: "h1", Competitors: map[string]string{"go": "g1", "axum": "a1", "roux": "r1"}}
	cases := []struct {
		name    string
		keys    map[string]string
		harness string
		last    *BuildInfo
		want    []string
	}{
		{"one competitor moved", keys, "h1", last, []string{"axum"}},
		{"the harness moved", keys, "h2", last, names},
		{"no release before", keys, "h1", nil, names},
		{"a release before harness keys", keys, "h1", &BuildInfo{Competitors: last.Competitors}, names},
		{"nothing moved", last.Competitors, "h1", last, nil},
		{"a new competitor", map[string]string{"go": "g1", "axum": "a1", "roux": "r1", "new": "n1"}, "h1", last, []string{"new"}},
	}
	for _, c := range cases {
		order := names
		if c.keys["new"] != "" {
			order = append(slices.Clone(names), "new")
		}
		if got := smokeSet(order, c.keys, c.harness, c.last); !slices.Equal(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}
