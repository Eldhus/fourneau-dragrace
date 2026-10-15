package main

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The black box ends when what reads it goes away, journalctl with it: on
// a server kept between ad-hoc races, none outlives its race. It takes one
// sampling interval (10 s).
func TestBlackBoxEndsWithItsReader(t *testing.T) {
	t.Parallel()
	cmd := exec.Command("bash", "-c", blackBoxScript)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	group := -cmd.Process.Pid
	defer syscall.Kill(group, syscall.SIGKILL)
	reader := bufio.NewReader(out)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("no sample: %v", err)
		}
		if strings.Contains(line, " sample: ") {
			break
		}
	}
	out.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("the sampler outlived its reader")
	}
	// journalctl (or anything else it started) went with it.
	deadline := time.Now().Add(2 * time.Second)
	for !errors.Is(syscall.Kill(group, 0), syscall.ESRCH) {
		if time.Now().After(deadline) {
			t.Fatal("a child of the black box outlived it")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// The black box's sampler says the memory, load and largest process of
// this machine (its kernel half needs root, which a droplet's SSH has).
func TestBlackBoxSamples(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-c", blackBoxScript)
	// Its children (journalctl, sleep) outlive bash with the pipe open.
	cmd.WaitDelay = 100 * time.Millisecond
	output, _ := cmd.Output()
	sample := ""
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, " sample: ") {
			sample = line
		}
	}
	for _, want := range []string{"MemAvailable: ", "SwapFree: ", " MiB", " load ", " largest "} {
		if !strings.Contains(sample, want) {
			t.Fatalf("no %q in the sample %q", want, sample)
		}
	}
}

func TestBlackBoxTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "server.log")
	os.WriteFile(path, []byte("one\ntwo\nthree\n"), 0o600)
	if got := blackBoxTail(path, 2); got != "two | three" {
		t.Fatalf("got %q", got)
	}
	if got := blackBoxTail("", 2); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestServerState(t *testing.T) {
	state := serverState(context.Background(), Target{Server: LocalMachine{}})
	if !strings.HasPrefix(state, "up since ") || !strings.Contains(state, "MemAvailable ") {
		t.Fatalf("got %q", state)
	}
}
