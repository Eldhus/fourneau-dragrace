package main

import (
	"strings"
	"testing"
)

// Only cook with the owner's key logs in; any other login, or a line not in
// sshd's form, is a difference.
func TestCompareLogins(t *testing.T) {
	const owner = "SHA256:tbmU6Jkt7BxbJxiIbG08XFWCglG6wyGV3poevW6c0Nc"
	login := func(text string) []string { return strings.Fields("login " + text) }
	cases := []struct {
		name   string
		lines  [][]string
		differ int
	}{
		{"none", nil, 0},
		{"the owner's", [][]string{
			login("Accepted publickey for cook from 24.154.115.162 port 35618 ssh2: RSA " + owner),
			login("Accepted publickey for cook from 10.0.0.2 port 1 ssh2: RSA " + owner),
		}, 0},
		{"another key", [][]string{
			login("Accepted publickey for cook from 1.2.3.4 port 1 ssh2: ED25519 SHA256:other"),
		}, 1},
		{"another user", [][]string{
			login("Accepted publickey for root from 1.2.3.4 port 1 ssh2: RSA " + owner),
		}, 1},
		{"a password", [][]string{
			login("Accepted password for cook from 1.2.3.4 port 1 ssh2"),
		}, 1},
		{"not a login line", [][]string{{"port", "22/tcp"}}, 0},
	}
	for _, c := range cases {
		report := &findings{}
		compareLogins(report, c.lines, owner)
		if report.differ != c.differ {
			t.Fatalf("%s: %d differences, want %d", c.name, report.differ, c.differ)
		}
	}
}
