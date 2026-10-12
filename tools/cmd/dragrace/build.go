package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
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
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	if race.hasMixed() {
		if err := buildConduitDatabase(ctx, root); err != nil {
			return err
		}
	}
	// Each by its key (keys.go): from the store when it has the key, else
	// built and stored. The keys are taken before any step runs, as the
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

// buildCompetitor runs one competitor's build steps in root, into root's
// out/bin.
func buildCompetitor(ctx context.Context, root string, tools Toolchain, competitor Competitor) error {
	out := binDir(root)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	// No {fourneau}: a tree read by path is an input (keys.go), named in
	// competitor.json, so its key covers it.
	values := map[string]string{
		"out":  out,
		"zig":  tools.Zig,
		"roc":  tools.Roc,
		"roux": tools.Roux,
	}
	for _, step := range competitor.Build {
		dir := expand(step.Cwd, values)
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(root, dir)
		}
		argv := make([]string, len(step.Argv))
		for i, arg := range step.Argv {
			argv[i] = expand(arg, values)
		}
		if err := run(ctx, dir, step.Env, argv...); err != nil {
			return fmt.Errorf("building %s: %w", competitor.Name, err)
		}
	}
	binary := filepath.Join(out, competitor.Name)
	if _, err := os.Stat(binary); err != nil {
		return fmt.Errorf("building %s: no %s afterwards", competitor.Name, binary)
	}
	return nil
}
