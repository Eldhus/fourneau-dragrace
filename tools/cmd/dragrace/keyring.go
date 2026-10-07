package main

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// The owner's secrets for self-hosting live in their keyring
// (secret-tool, service fourneau-dragrace), never in a file or on a
// command line: the racer and manual tokens, made here when missing, and
// the GitHub token the owner stores (SECURITY.md). They travel to a host
// over SSH, on standard input.

const keyringService = "fourneau-dragrace"

// keyringLookup reads a secret; a missing one is an error.
func keyringLookup(ctx context.Context, name string) (string, error) {
	output, err := exec.CommandContext(ctx, "secret-tool", "lookup", "service", keyringService,
		"name", name).Output()
	secret := strings.TrimSpace(string(output))
	if err != nil || secret == "" {
		return "", fmt.Errorf("no %s in the keyring (secret-tool lookup service %s name %s)",
			name, keyringService, name)
	}
	return secret, nil
}

// keyringToken reads a token, making and storing a new random one if the
// keyring has none.
func keyringToken(ctx context.Context, name string) (string, error) {
	if token, err := keyringLookup(ctx, name); err == nil {
		return token, nil
	}
	token := randomToken()
	store := exec.CommandContext(ctx, "secret-tool", "store", "--label", keyringService+"-"+name,
		"service", keyringService, "name", name)
	store.Stdin = strings.NewReader(token)
	if output, err := store.CombinedOutput(); err != nil {
		return "", fmt.Errorf("secret-tool store %s: %v: %s", name, err, output)
	}
	return token, nil
}
