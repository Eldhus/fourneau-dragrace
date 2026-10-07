package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// commandBundle packs a build for a release (build.yml; docs/self-hosting.md,
// "Builds and deploys"), into -out:
//
//   - race.tar.gz: a checkout as a race needs it, for the racer and its
//     workers: race.json, versions.json, workloads/, each competitor's
//     competitor.json, and out/bin with the competitors, oha and this
//     dragrace binary;
//   - site.tar.gz: the site, for the site host: dragrace-site and static/;
//   - build.json: the commits built and each file's SHA-256 (the release's
//     body too).
//
// Everything must be built first (dragrace build, dragrace site build).
func commandBundle(ctx context.Context, root string, args []string) error {
	flags := newFlags("bundle")
	out := flags.String("out", filepath.Join(outDir(root), "bundle"), "where the files go")
	flags.Parse(args)
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	fingerprint, err := fingerprintOf(root)
	if err != nil {
		return err
	}
	if fingerprint.DragraceDirty || fingerprint.FourneauDirty || fingerprint.RouxDirty {
		return fmt.Errorf("a checkout has changes not committed: a build is of commits")
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	raceFiles := []bundled{{"race.json", filepath.Join(root, "race.json")},
		{"versions.json", filepath.Join(root, "versions.json")},
		{"out/bin/oha", tools.Oha}, {"out/bin/dragrace", self}}
	trees := []bundledTree{{"workloads", filepath.Join(root, "workloads")}}
	if race.hasMixed() {
		raceFiles = append(raceFiles, bundled{"out/conduit/conduit.db", conduitDatabase(root)})
	}
	for _, name := range race.Competitors {
		raceFiles = append(raceFiles,
			bundled{"competitors/" + name + "/competitor.json",
				filepath.Join(root, "competitors", name, "competitor.json")},
			bundled{"out/bin/" + name, filepath.Join(binDir(root), name)})
	}
	info := BuildInfo{Commits: map[string]string{"fourneau-dragrace": fingerprint.Dragrace,
		"fourneau": fingerprint.Fourneau, "roux": fingerprint.Roux},
		BuiltAt: time.Now().UTC(), Files: map[string]string{}}
	if info.Files["race.tar.gz"], err = writeTarball(filepath.Join(*out, "race.tar.gz"),
		raceFiles, trees); err != nil {
		return err
	}
	if info.Files["site.tar.gz"], err = writeTarball(filepath.Join(*out, "site.tar.gz"),
		[]bundled{{"dragrace-site", siteBinary(root)}},
		[]bundledTree{{"static", filepath.Join(root, "site", "static")}}); err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*out, "build.json"), encoded, 0o644); err != nil {
		return err
	}
	fmt.Printf("bundled into %s:\n%s\n", *out, encoded)
	return nil
}

// bundled is a file and its path in a tarball; bundledTree, a directory.
type bundled struct{ name, path string }
type bundledTree struct{ name, path string }

// tarballFilesMax bounds a tree walked into a tarball.
const tarballFilesMax = 1024

// writeTarball writes a gzipped tarball and returns its SHA-256. Files keep
// their mode's execute bit; owners and times are left out, so the same
// files make the same tarball.
func writeTarball(path string, files []bundled, trees []bundledTree) (string, error) {
	for _, tree := range trees {
		count := 0
		err := filepath.WalkDir(tree.path, func(file string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			if count++; count > tarballFilesMax {
				return fmt.Errorf("%s: over %d files", tree.path, tarballFilesMax)
			}
			relative, err := filepath.Rel(tree.path, file)
			if err != nil {
				return err
			}
			files = append(files, bundled{tree.name + "/" + filepath.ToSlash(relative), file})
			return nil
		})
		if err != nil {
			return "", err
		}
	}
	output, err := os.Create(path)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	zipped := gzip.NewWriter(io.MultiWriter(output, hash))
	archive := tar.NewWriter(zipped)
	for _, file := range files {
		if err := addToTarball(archive, file); err != nil {
			output.Close()
			return "", err
		}
	}
	if err := archive.Close(); err != nil {
		return "", err
	}
	if err := zipped.Close(); err != nil {
		return "", err
	}
	if err := output.Close(); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func addToTarball(archive *tar.Writer, file bundled) error {
	source, err := os.Open(file.path)
	if err != nil {
		return err
	}
	defer source.Close()
	stat, err := source.Stat()
	if err != nil {
		return err
	}
	if !stat.Mode().IsRegular() {
		return fmt.Errorf("%s: not a regular file", file.path)
	}
	mode := int64(0o644)
	if stat.Mode()&0o111 != 0 {
		mode = 0o755
	}
	header := &tar.Header{Name: file.name, Mode: mode, Size: stat.Size(), Typeflag: tar.TypeReg,
		Format: tar.FormatPAX}
	if err := archive.WriteHeader(header); err != nil {
		return err
	}
	_, err = io.Copy(archive, source)
	return err
}
