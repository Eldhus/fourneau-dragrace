package main

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// A failed command's error says what it printed last, and stays an
// ExitError underneath (hosts.go tells ssh's 255 apart).
func TestStderrTailWraps(t *testing.T) {
	cmd := exec.Command("sh", "-c", "echo 'ssh: connect to host 10.0.0.2 port 22:' >&2; "+
		"echo 'Connection timed out' >&2; exit 255")
	stderr := &stderrTail{}
	cmd.Stderr = stderr
	err := stderr.wrap(cmd.Run())
	want := "exit status 255: ssh: connect to host 10.0.0.2 port 22: Connection timed out"
	if err == nil || err.Error() != want {
		t.Fatalf("got %v, want %q", err, want)
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 255 {
		t.Fatalf("the ExitError is lost: %v", err)
	}
	long := &stderrTail{}
	long.Write([]byte(strings.Repeat("x", 1000) + "the end"))
	if len(long.tail) != stderrTailBytes || !strings.HasSuffix(string(long.tail), "the end") {
		t.Fatalf("kept %d bytes", len(long.tail))
	}
	if (&stderrTail{}).wrap(nil) != nil {
		t.Fatal("no error must stay none")
	}
}
