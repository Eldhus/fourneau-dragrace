package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// keyRepo is a checkout as competitorKey reads one: two competitors,
// workloads/, versions.json, and target/ ignored; and a fourneau checkout.
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
		filepath.Join(root, "versions.json"):                     "{}\n",
		filepath.Join(tools.Fourneau, "src/fourneau.zig"):        "pub const x = 1;\n",
		filepath.Join(tools.Roux, "build.json"):                  `{"roux": "a", "fourneau": "b"}`,
	}
	for path, text := range files {
		writeFile(t, path, text)
	}
	for _, dir := range []string{root, tools.Fourneau} {
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
	plain := Competitor{Name: "plain", Build: []Step{{Cwd: "competitors/plain", Argv: []string{"go", "build"}}}}
	zig := Competitor{Name: "plain", Build: []Step{{Cwd: "competitors/plain", Argv: []string{"{zig}", "build"}}}}
	roux := Competitor{Name: "plain", Build: []Step{{Cwd: "{roux}", Argv: []string{"x"}}}}
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
		t.Fatal("the tools a competitor's steps name are not in its key")
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
		{"versions.json", "versions.json", `{"x": 1}`, [3]bool{true, true, true}},
		{"fourneau", "../fourneau/src/fourneau.zig", "pub const x = 2;\n", [3]bool{false, true, false}},
		{"the roux build", "../roux/build.json", `{"roux": "c", "fourneau": "b"}`, [3]bool{false, false, true}},
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
