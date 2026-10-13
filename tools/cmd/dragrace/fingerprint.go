package main

import (
	"context"
)

// Fingerprint is the three checkouts' commits (this repository, fourneau,
// roux) and whether each has uncommitted changes (git status --porcelain,
// untracked files included).
type Fingerprint struct {
	Dragrace      string `json:"dragrace"`
	DragraceDirty bool   `json:"dragrace_dirty"`
	Fourneau      string `json:"fourneau"`
	FourneauDirty bool   `json:"fourneau_dirty"`
	Roux          string `json:"roux"`
	RouxDirty     bool   `json:"roux_dirty"`
}

func fingerprintOf(root string) (Fingerprint, error) {
	ctx := context.Background()
	var fingerprint Fingerprint
	var err error
	fingerprint.Dragrace, fingerprint.DragraceDirty, err = commitOf(ctx, root)
	if err != nil {
		return fingerprint, err
	}
	fingerprint.Fourneau, fingerprint.FourneauDirty, err =
		commitOf(ctx, checkoutPath(root, "fourneau"))
	if err != nil {
		return fingerprint, err
	}
	fingerprint.Roux, fingerprint.RouxDirty, err = commitOf(ctx, checkoutPath(root, "roux"))
	return fingerprint, err
}

// commitOf is a checkout's HEAD and whether it has uncommitted changes.
func commitOf(ctx context.Context, dir string) (string, bool, error) {
	commit, err := output(ctx, dir, "git", "rev-parse", "HEAD")
	if err != nil {
		return "", false, err
	}
	status, err := output(ctx, dir, "git", "status", "--porcelain")
	return commit, status != "", err
}
