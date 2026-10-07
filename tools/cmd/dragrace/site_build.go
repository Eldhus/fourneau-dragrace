package main

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
)

// The site is a roux app (site/): every page a rocstache template, the races
// read from site/data on each request. It runs on what it races, so it is
// built as the roux competitor is: roux's platform and rocstache-gen from
// the checkout beside this one, the templates compiled to Roc, the app's
// expects run, then one static binary.

// siteBinary is the built site: out/bin/dragrace-site.
func siteBinary(root string) string { return filepath.Join(binDir(root), "dragrace-site") }

func siteBuildCommand(ctx context.Context, root string, args []string) error {
	flags := newFlags("site build")
	flags.Parse(args)
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	if err := siteBuild(ctx, root, tools); err != nil {
		return err
	}
	fmt.Printf("built %s; run it from site/ (ROUX_PORT=8090 for a local look)\n", siteBinary(root))
	return nil
}

func siteBuild(ctx context.Context, root string, tools Toolchain) error {
	for _, step := range []string{"platform", "tools"} {
		if err := run(ctx, tools.Roux, nil, tools.Zig, "build", step); err != nil {
			return err
		}
	}
	dir := filepath.Join(root, "site")
	templates, err := filepath.Glob(filepath.Join(dir, "*.rocstache"))
	if err != nil {
		return err
	}
	if len(templates) == 0 {
		return fmt.Errorf("no templates in %s", dir)
	}
	generate := filepath.Join(tools.Roux, "zig-out", "bin", "rocstache-gen")
	for _, template := range templates {
		name := filepath.Base(template)
		module := strings.TrimSuffix(name, ".rocstache") + ".roc"
		if err := run(ctx, dir, nil, generate, "-o", module, name); err != nil {
			return err
		}
	}
	if err := run(ctx, dir, nil, tools.Roc, "test", "main.roc"); err != nil {
		return err
	}
	return run(ctx, dir, nil, tools.Roc, "build", "main.roc", "--output="+siteBinary(root))
}
