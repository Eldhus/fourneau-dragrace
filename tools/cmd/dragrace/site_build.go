package main

import (
	"context"
	"fmt"
	"path/filepath"
)

// The site is a roux app (site/): every page a rocstache template, the races
// in its SQLite database (site/db: the schema and queries, typed by
// roux-db). It runs on what it races, so it is built as the roux competitor
// is: roux's platform and tools from the checkout beside this one, then
// `roux build`, which types the queries, writes each template's contract
// module, compiles the templates with Zig and the app with roc, and links
// one static binary; then the app's expects run.

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
	fmt.Printf("built %s; run it from site/ (ROUX_PORT=8090 for a local look; it makes site.db there)\n", siteBinary(root))
	return nil
}

func siteBuild(ctx context.Context, root string, tools Toolchain) error {
	for _, step := range []string{"platform", "tools"} {
		if err := run(ctx, tools.Roux, nil, tools.Zig, "build", step); err != nil {
			return err
		}
	}
	dir := filepath.Join(root, "site")
	roux := filepath.Join(tools.Roux, "zig-out", "bin", "roux")
	if err := run(ctx, dir, nil, roux, "build", "--roc="+tools.Roc, "--output="+siteBinary(root), "main.roc"); err != nil {
		return err
	}
	return run(ctx, dir, nil, tools.Roc, "test", "main.roc")
}
