package main

import (
	"context"
	"fmt"
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
	values := map[string]string{
		"out":      out,
		"zig":      tools.Zig,
		"roc":      tools.Roc,
		"fourneau": tools.Fourneau,
		"roux":     tools.Roux,
	}
	for _, competitor := range competitors {
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
	}
	return nil
}
