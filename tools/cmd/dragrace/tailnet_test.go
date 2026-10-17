package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The name takes the keys already pinned for the public address, and loses
// any it had (a host made again under the same name); nothing else changes.
func TestPinUnder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known-hosts")
	old := "site.example ssh-ed25519 AAAAold\n" +
		"dragrace-site ssh-ed25519 AAAAstale\n" +
		"site.example ssh-rsa AAAAoldrsa\n" +
		"other ssh-ed25519 AAAAother\n"
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pinUnder(path, "site.example", "dragrace-site"); err != nil {
		t.Fatal(err)
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "site.example ssh-ed25519 AAAAold\n" +
		"site.example ssh-rsa AAAAoldrsa\n" +
		"other ssh-ed25519 AAAAother\n" +
		"dragrace-site ssh-ed25519 AAAAold\n" +
		"dragrace-site ssh-rsa AAAAoldrsa\n"
	if string(bytes) != want {
		t.Fatalf("got:\n%s\nwant:\n%s", bytes, want)
	}
	if err := pinUnder(path, "nowhere", "dragrace-site"); err == nil {
		t.Fatal("a host with no pinned key gave its name some")
	}
}

// A host is joined as its name, running, with its tag alone: another tag
// would let a grant meant for it reach the host, or the host reach more.
func TestTailscaleJoined(t *testing.T) {
	var status tailscaleStatus
	status.BackendState = "Running"
	status.Self.DNSName = "dragrace-site.example.ts.net."
	status.Self.Tags = []string{"tag:dragrace-site"}
	if err := status.joined("dragrace-site"); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*tailscaleStatus){
		func(s *tailscaleStatus) { s.BackendState = "NeedsLogin" },
		func(s *tailscaleStatus) { s.Self.DNSName = "dragrace-site-1.example.ts.net." },
		func(s *tailscaleStatus) { s.Self.Tags = []string{"tag:dragrace-site", "tag:other"} },
		func(s *tailscaleStatus) { s.Self.Tags = nil },
	} {
		changed := status
		change(&changed)
		if err := changed.joined("dragrace-site"); err == nil {
			t.Fatalf("joined: %+v", changed)
		}
	}
}

// SSH only from the tailnet; the public ports as asked.
func TestFirewallRules(t *testing.T) {
	got := strings.Join(firewallRules("80", "443"), "; ")
	if got != "allow 80/tcp; allow 443/tcp; allow in on tailscale0 to any port 22 proto tcp" {
		t.Fatalf("site: %s", got)
	}
	if got := strings.Join(firewallRules(), "; "); got != tailnetSSHRule {
		t.Fatalf("racer: %s", got)
	}
}
