// Command dragrace builds the competitors, races them (on this machine or
// on DigitalOcean droplets), and renders the results site.
//
//	dragrace toolchain              fetch and verify the pinned Zig, Roc, oha
//	dragrace build                  build every competitor into out/bin
//	dragrace race local [flags]     race on this machine, server and loader on
//	                                separate CPUs
//	dragrace race cloud [flags]     race on fresh droplets (DIGITALOCEAN_TOKEN)
//	dragrace sizes [-prefix c]      droplet sizes and prices in race.json's region
//	dragrace reap                   delete race droplets older than allowed
//	dragrace fingerprint            the commits a race would race, as JSON
//	dragrace changed DIR            exit 0 if they differ from DIR's latest
//	                                run, 1 if not (the nightly's gate)
//	dragrace publish RUN.json...    file runs into site/data (or -into DIR),
//	                                which the site reads on each request
//	dragrace site build             build the site (a roux app) into out/bin
//	dragrace site provision|install-server|deploy   the 24/7 site droplet
//	dragrace worker [-config F]     race one class from its loader, posting
//	                                to the site (the racer starts it)
//
// The services of self-hosting (docs/self-hosting.md), which run outside
// a checkout:
//
//	dragrace guard [-config F]      the racer's DigitalOcean token and budget
//	dragrace racer serve            take the site's requests and race them
//	dragrace racer check            ask the site for a check (the 03:00 timer)
//	dragrace racer once -local DIR  take one request, racing on this machine
//
// Every other command runs from anywhere inside the repository.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	log.SetFlags(log.Ltime)
	log.SetPrefix("dragrace: ")
	if len(os.Args) < 2 {
		usage()
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := dispatchService(ctx, os.Args[1], os.Args[2:])
	if errors.Is(err, errNotService) {
		root, rootErr := repositoryRoot()
		if rootErr != nil {
			log.Fatal(rootErr)
		}
		err = dispatch(ctx, root, os.Args[1], os.Args[2:])
	}
	if err != nil {
		var exit exitCode
		if errors.As(err, &exit) {
			os.Exit(int(exit))
		}
		log.Fatal(err)
	}
}

var errNotService = errors.New("not a service")

// dispatchService runs the commands that need no checkout.
func dispatchService(ctx context.Context, command string, args []string) error {
	switch command {
	case "guard":
		return commandGuard(ctx, args)
	case "racer":
		return commandRacer(ctx, args)
	}
	return errNotService
}

// exitCode ends the program with a code and no message (dragrace changed).
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit %d", int(e)) }

func dispatch(ctx context.Context, root, command string, args []string) error {
	switch command {
	case "toolchain":
		_, err := loadToolchain(ctx, root)
		return err
	case "build":
		return commandBuild(ctx, root, args)
	case "race":
		if len(args) == 0 {
			usage()
		}
		switch args[0] {
		case "local":
			return commandRaceLocal(ctx, root, args[1:])
		case "cloud":
			return commandRaceCloud(ctx, root, args[1:])
		}
	case "sizes":
		return commandSizes(ctx, root, args)
	case "reap":
		return commandReap(ctx, root, args)
	case "fingerprint":
		return commandFingerprint(root)
	case "changed":
		return commandChanged(root, args)
	case "publish":
		return commandPublish(root, args)
	case "site":
		return commandSite(ctx, root, args)
	case "worker":
		return commandWorker(ctx, root, args)
	}
	usage()
	return nil
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage: dragrace COMMAND
  toolchain | build | race local | race cloud | sizes | reap | fingerprint |
  changed DIR | publish RUN.json... | site build | site provision |
  site install-server | site deploy | guard
See README.md, RACING.md and docs/self-hosting.md.`)
	os.Exit(2)
}

// repositoryRoot walks up from the working directory to race.json.
func repositoryRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for range 64 {
		if _, err := os.Stat(filepath.Join(dir, "race.json")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", errors.New("not inside fourneau-dragrace (no race.json above here)")
}

// run executes argv in dir with extra environment, streaming its output.
func run(ctx context.Context, dir string, env map[string]string, argv ...string) error {
	log.Printf("$ %s", strings.Join(argv, " "))
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	for key, value := range env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w", argv[0], err)
	}
	return nil
}

// output executes argv and returns its standard output.
func output(ctx context.Context, dir string, argv ...string) (string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	cmd.Stderr = os.Stderr
	bytes, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s: %w", strings.Join(argv, " "), err)
	}
	return strings.TrimSpace(string(bytes)), nil
}

func newFlags(name string) *flag.FlagSet {
	return flag.NewFlagSet(name, flag.ExitOnError)
}
