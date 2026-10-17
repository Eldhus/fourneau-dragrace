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
	// Control, if set, is an ssh ControlPath: every call shares one kept
	// connection, a round trip a call instead of a handshake's several
	// (an ad-hoc race from afar: 90-140 ms to the region), and only the
	// first meets a new droplet's sshd while bots flood it (its MaxStartups
	// drops new connections at random, ours too: 2026-10-16 and 10-17).
	Control string
}

func (machine SSHMachine) options() []string {
	options := machine.baseOptions()
	if machine.Control != "" {
		options = append(options, "-o", "ControlMaster=auto", "-o", "ControlPath="+machine.Control,
			"-o", "ControlPersist=600")
	}
	return options
}

// closeControl ends the kept connection, if any.
func (machine SSHMachine) closeControl() {
	if machine.Control == "" {
		return
	}
	exec.Command("ssh", "-o", "ControlPath="+machine.Control, "-O", "exit", "x").Run()
}

func (machine SSHMachine) baseOptions() []string {
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
	stderr := &stderrTail{}
	cmd.Stderr = stderr
	bytes, err := cmd.Output()
	return strings.TrimRight(string(bytes), "\n"), stderr.wrap(err)
}

// stderrTail passes a command's standard error on to ours and keeps its
// end, so an error says why: ssh's "exit status 255" alone does not say
// whether the host refused, timed out or went away mid-command.
type stderrTail struct {
	tail []byte
}

const stderrTailBytes = 300

func (tail *stderrTail) Write(bytes []byte) (int, error) {
	os.Stderr.Write(bytes)
	tail.tail = append(tail.tail, bytes...)
	if len(tail.tail) > stderrTailBytes {
		tail.tail = tail.tail[len(tail.tail)-stderrTailBytes:]
	}
	return len(bytes), nil
}

func (tail *stderrTail) wrap(err error) error {
	said := strings.Join(strings.Fields(string(tail.tail)), " ")
	if err == nil || said == "" {
		return err
	}
	return fmt.Errorf("%w: %s", err, said)
}

// ShellInput runs a script with input on its standard input: how a secret
// reaches a host, never on a command line.
func (machine SSHMachine) ShellInput(ctx context.Context, script, input string) error {
	argv := append(machine.options(), machine.User+"@"+machine.Host, "bash -c "+quote(script))
	cmd := exec.CommandContext(ctx, "ssh", argv...)
	cmd.Stdin = strings.NewReader(input)
	stderr := &stderrTail{}
	cmd.Stderr = stderr
	return stderr.wrap(cmd.Run())
}

func (machine SSHMachine) Put(ctx context.Context, local, remote string) error {
	if _, err := machine.Shell(ctx, "mkdir -p "+quote(filepath.Dir(remote))); err != nil {
		return err
	}
	argv := append(machine.options(), local, machine.User+"@"+machine.Host+":"+remote)
	cmd := exec.CommandContext(ctx, "scp", argv...)
	stderr := &stderrTail{}
	cmd.Stderr = stderr
	return stderr.wrap(cmd.Run())
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

// newKeyPair makes an ed25519 key for one run or ad-hoc session, in dir.
func newKeyPair(ctx context.Context, dir, comment string) (private, public string, err error) {
	private = filepath.Join(dir, "key")
	if err := run(ctx, dir, nil, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment,
		"-f", private); err != nil {
		return "", "", err
	}
	bytes, err := os.ReadFile(private + ".pub")
	return private, strings.TrimSpace(string(bytes)), err
}
