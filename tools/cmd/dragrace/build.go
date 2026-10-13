package main

import (
	"context"
	"fmt"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// outDir is where builds, results and the site go (ignored by git).
func outDir(root string) string { return filepath.Join(root, "out") }

func binDir(root string) string { return filepath.Join(outDir(root), "bin") }

func commandBuild(ctx context.Context, root string, args []string) error {
	flags := newFlags("build")
	only := flags.String("competitors", "", "comma-separated names (default: race.json's)")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	names := race.Competitors
	if *only != "" {
		names = strings.Split(*only, ",")
	}
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	competitors, err := loadCompetitors(root, names)
	if err != nil {
		return err
	}
	return buildAll(ctx, root, tools, competitors)
}

func buildAll(ctx context.Context, root string, tools Toolchain, competitors []Competitor) error {
	out := binDir(root)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	// Every server is given the seeded database (startServer).
	if err := buildConduitDatabase(ctx, root); err != nil {
		return err
	}
	// Each by its key (keys.go): from the store when it has the key, else
	// built and stored. The keys are taken before any build runs, as the
	// checkout was, and recorded for the bundle.
	keys := map[string]string{}
	for _, competitor := range competitors {
		key, err := competitorKey(ctx, root, tools, competitor)
		if err != nil {
			return err
		}
		keys[competitor.Name] = key
		stored, err := fromStore(root, competitor.Name, key)
		if err != nil {
			return err
		}
		if stored {
			log.Printf("%s: from the store, key %s", competitor.Name, key[:12])
			continue
		}
		if err := buildCompetitor(ctx, root, tools, competitor); err != nil {
			return err
		}
		if err := toStore(root, competitor.Name, key); err != nil {
			return err
		}
		log.Printf("%s: built and stored, key %s", competitor.Name, key[:12])
	}
	return writeCompetitorKeys(root, keys)
}

// buildCompetitor runs one competitor's build command in its directory and
// copies the binary it names to root's out/bin/NAME. The pinned tools it
// may run (pinned) come first on its PATH, and a command that starts one
// gets the pinned one.
func buildCompetitor(ctx context.Context, root string, tools Toolchain, competitor Competitor) error {
	out := binDir(root)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	dir := filepath.Join(root, "competitors", competitor.Name)
	pinned := competitor.pinned(tools)
	env := maps.Clone(competitor.Build.Env)
	if env == nil {
		env = map[string]string{}
	}
	path := []string{}
	for _, name := range slices.Sorted(maps.Keys(pinned)) {
		path = append(path, filepath.Dir(pinned[name]))
	}
	env["PATH"] = strings.Join(append(path, os.Getenv("PATH")), string(os.PathListSeparator))
	argv := slices.Clone(competitor.Build.Argv)
	if tool, found := pinned[argv[0]]; found {
		argv[0] = tool
	}
	if err := run(ctx, dir, env, argv...); err != nil {
		return fmt.Errorf("building %s: %w", competitor.Name, err)
	}
	if err := copyFile(filepath.Join(dir, competitor.Build.Binary),
		filepath.Join(out, competitor.Name)); err != nil {
		return fmt.Errorf("building %s: %w", competitor.Name, err)
	}
	return nil
}
