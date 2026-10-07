package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// commandChanged exits 0 when the commits differ from the latest run in
// the history directory (or there is none), 1 when they are the same.
func commandChanged(root string, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: dragrace changed HISTORY_DIR")
	}
	now, err := fingerprintOf(root)
	if err != nil {
		return err
	}
	var latest Run
	err = readJSON(filepath.Join(args[0], "latest.json"), &latest)
	if os.IsNotExist(err) {
		fmt.Println("changed: no earlier run")
		return nil
	}
	if err != nil {
		return err
	}
	before := latest.Fingerprint
	if before.Dragrace == now.Dragrace && before.Fourneau == now.Fourneau && before.Roux == now.Roux {
		fmt.Printf("unchanged since run %s\n", latest.ID)
		return exitCode(1)
	}
	fmt.Printf("changed since run %s: dragrace %.7s -> %.7s, fourneau %.7s -> %.7s, roux %.7s -> %.7s\n",
		latest.ID, before.Dragrace, now.Dragrace, before.Fourneau, now.Fourneau, before.Roux, now.Roux)
	return nil
}
