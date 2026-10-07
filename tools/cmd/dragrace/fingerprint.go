package main

import (
	"context"
	"encoding/json"
	"fmt"
)

// Fingerprint is what a race raced: the commits of this repository, of
// fourneau and of roux. The nightly races only when it differs from the last
// run's.
type Fingerprint struct {
	Dragrace      string `json:"dragrace"`
	DragraceDirty bool   `json:"dragrace_dirty"`
	Fourneau      string `json:"fourneau"`
	FourneauDirty bool   `json:"fourneau_dirty"`
	Roux          string `json:"roux"`
	RouxDirty     bool   `json:"roux_dirty"`
}

func fingerprintOf(root string) (Fingerprint, error) {
	versions, err := loadVersions(root)
	if err != nil {
		return Fingerprint{}, err
	}
	ctx := context.Background()
	var fingerprint Fingerprint
	fingerprint.Dragrace, fingerprint.DragraceDirty, err = commitOf(ctx, root)
	if err != nil {
		return fingerprint, err
	}
	fingerprint.Fourneau, fingerprint.FourneauDirty, err =
		commitOf(ctx, checkoutPath(root, versions.Fourneau))
	if err != nil {
		return fingerprint, err
	}
	fingerprint.Roux, fingerprint.RouxDirty, err = commitOf(ctx, checkoutPath(root, versions.Roux))
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

func commandFingerprint(root string) error {
	fingerprint, err := fingerprintOf(root)
	if err != nil {
		return err
	}
	bytes, err := json.MarshalIndent(fingerprint, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(bytes))
	return nil
}
