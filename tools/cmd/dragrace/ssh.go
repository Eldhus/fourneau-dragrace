package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// SSHMachine is a droplet, reached with the system's ssh and scp.
type SSHMachine struct {
	User       string
	Host       string
	Key        string // private key file
	KnownHosts string // this run's own known_hosts
}

func (machine SSHMachine) options() []string {
	return []string{
		"-i", machine.Key,
		"-o", "BatchMode=yes",
		"-o", "IdentitiesOnly=yes",
		// A new droplet's host key cannot be known in advance: it is
		// trusted on first use, into a known_hosts file for this run only.
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=" + machine.KnownHosts,
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "LogLevel=ERROR",
	}
}

func (machine SSHMachine) Shell(ctx context.Context, script string) (string, error) {
	argv := append(machine.options(), machine.User+"@"+machine.Host, "bash -c "+quote(script))
	cmd := exec.CommandContext(ctx, "ssh", argv...)
	cmd.Stderr = os.Stderr
	bytes, err := cmd.Output()
	return strings.TrimRight(string(bytes), "\n"), err
}

func (machine SSHMachine) Put(ctx context.Context, local, remote string) error {
	if _, err := machine.Shell(ctx, "mkdir -p "+quote(filepath.Dir(remote))); err != nil {
		return err
	}
	argv := append(machine.options(), local, machine.User+"@"+machine.Host+":"+remote)
	cmd := exec.CommandContext(ctx, "scp", argv...)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// waitSSH waits until the droplet accepts SSH and cloud-init has finished.
func waitSSH(ctx context.Context, machine SSHMachine) error {
	for range 60 {
		if _, err := machine.Shell(ctx, "cloud-init status --wait > /dev/null; true"); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
	return fmt.Errorf("%s: no SSH after 5 minutes", machine.Host)
}

// newKeyPair makes an ed25519 key for one run, in dir.
func newKeyPair(ctx context.Context, dir, comment string) (private, public string, err error) {
	private = filepath.Join(dir, "key")
	if err := run(ctx, dir, nil, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment,
		"-f", private); err != nil {
		return "", "", err
	}
	bytes, err := os.ReadFile(private + ".pub")
	return private, strings.TrimSpace(string(bytes)), err
}
