package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// `dragrace site dev`: the site rebuilt and reloaded as it is edited, for
// work on the UI (the owner, 2026-10-07). Races and deploys keep `site
// build`'s optimized build.
//
// roux's own dev server does the work (`roux dev`, roux's
// tools/roux/dev.zig), which this command's first version (a Go watcher
// and a proxy) was the testing ground for: content hashes decide what an
// edit needs, a page's markup compiles one template's object and no Roc,
// the app restarts, and the host itself serves the reload stream and
// adds the script to each page, so no proxy. Here: roux's platform and
// tools built, then `roux dev` on site/, its static files watched.
func siteDevCommand(ctx context.Context, root string, args []string) error {
	flags := newFlags("site dev")
	port := flags.Int("port", 8090, "the site's port: open http://127.0.0.1:PORT/")
	flags.Parse(args)
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	for _, step := range []string{"platform", "tools"} {
		if err := run(ctx, tools.Roux, nil, tools.Zig, "build", step); err != nil {
			return err
		}
	}
	roux := filepath.Join(tools.Roux, "zig-out", "bin", "roux")
	argv := []string{roux, "dev", "--roc=" + tools.Roc, fmt.Sprintf("--port=%d", *port), "--static=static", "main.roc"}
	log.Printf("dev: http://127.0.0.1:%d/; editing site/ rebuilds", *port)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = filepath.Join(root, "site")
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	// Stopped, roux dev stops the app first: a TERM, not the default kill,
	// which would leave the app running.
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		return fmt.Errorf("roux dev: %w", err)
	}
	return nil
}
