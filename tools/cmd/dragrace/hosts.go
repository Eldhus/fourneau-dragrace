package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// `dragrace hosts check`: the two hosts against this checkout, read only.
// The boxes are set up by `site install-server` and `racer install`; this
// says when one has drifted from them. Each host's files are in hosts/ (common/ on both,
// then site/ or racer/), each at its install path; an install puts them in
// place and lists them, with the binaries it installs, in SHA256SUMS on the
// host. The check compares that list with the one this checkout and this
// binary make now, has the host check its files against it (sha256sum -c),
// and looks at the rest: the generated configs and credentials there, the
// retired files gone, the firewall's ports, the boot without an initramfs,
// the services up, no unit failed, a reboot pending, and each binary that
// updates itself (the site, the racer) against the newest release. It
// prints each finding and exits 1 on any difference.

// sumsPath is where an install lists what it put there, with each SHA-256.
const sumsPath = "/etc/dragrace-host/SHA256SUMS"

// hostTree is a host's files in hosts/ (common/, then its own), each named
// by its install path without the leading slash, in order.
func hostTree(root, host string) ([]bundled, error) {
	var files []bundled
	for _, dir := range []string{"common", host} {
		base := filepath.Join(root, "hosts", dir)
		err := filepath.WalkDir(base, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.IsDir() {
				return err
			}
			relative, err := filepath.Rel(base, path)
			if err != nil {
				return err
			}
			files = append(files, bundled{filepath.ToSlash(relative), path})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].name < files[j].name })
	for i := 1; i < len(files); i++ {
		if files[i].name == files[i-1].name {
			return nil, fmt.Errorf("hosts/: /%s twice", files[i].name)
		}
	}
	return files, nil
}

// hostSums is the SHA256SUMS an install writes, as sha256sum prints it:
// each of the host's files, and each binary it installs (path: local file).
// The racer's own binary is not one: it replaces itself.
func hostSums(files []bundled, binaries map[string]string) (string, error) {
	all := map[string]string{}
	maps.Copy(all, binaries)
	for _, file := range files {
		all["/"+file.name] = file.path
	}
	var sums strings.Builder
	for _, path := range slices.Sorted(maps.Keys(all)) {
		sum, err := fileSHA256(all[path])
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&sums, "%s  %s\n", sum, path)
	}
	return sums.String(), nil
}

// installHost puts the host's files in place as root, with SHA256SUMS and
// the generated files (path: content; not listed: this checkout does not
// hold what they say), from one tarball on SSH's standard input: each file
// root's, mode 644, its directory made if missing (755).
func installHost(ctx context.Context, machine SSHMachine, root, host string,
	binaries, generated map[string]string) error {
	files, err := hostTree(root, host)
	if err != nil {
		return err
	}
	sums, err := hostSums(files, binaries)
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "dragrace-host-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	written := map[string]string{sumsPath: sums}
	maps.Copy(written, generated)
	for index, path := range slices.Sorted(maps.Keys(written)) {
		local := filepath.Join(dir, fmt.Sprintf("%d", index))
		if err := os.WriteFile(local, []byte(written[path]), 0o600); err != nil {
			return err
		}
		files = append(files, bundled{strings.TrimPrefix(path, "/"), local})
	}
	tarball := filepath.Join(dir, "host.tar.gz")
	if _, err := writeTarball(tarball, files, nil); err != nil {
		return err
	}
	bytes, err := os.ReadFile(tarball)
	if err != nil {
		return err
	}
	// -m: the files' times are the install's, not the tarball's.
	return machine.ShellInput(ctx, "sudo tar -xzm -C /", string(bytes))
}

// hostWant is what one host should be, by this checkout.
type hostWant struct {
	name       string // its directory in hosts/
	address    string
	machine    SSHMachine
	binaries   map[string]string // installed: path, local file
	present    []string          // generated (prices, secrets): there
	ports      []string
	units      []string // services and timers, active
	racerBin   bool     // the racer's own binary, updated from releases
	siteDeploy bool     // the site's code, deployed from releases
}

func commandHosts(ctx context.Context, root string, args []string) error {
	if len(args) == 0 || args[0] != "check" {
		return fmt.Errorf("usage: dragrace hosts check [-racer HOST]")
	}
	flags := newFlags("hosts check")
	racer := flags.String("racer", "", "the racer's address (none: the site host alone)")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	flags.Parse(args[1:])
	self, err := os.Executable()
	if err != nil {
		return err
	}
	release, err := newestRelease(ctx)
	if err != nil {
		return err
	}
	differences := 0
	for _, want := range hostWants(root, *racer, *key, self) {
		found, err := checkHost(ctx, root, want, release)
		if err != nil {
			return fmt.Errorf("%s %s: %w", want.name, want.address, err)
		}
		differences += found
	}
	if differences > 0 {
		fmt.Printf("%d differences\n", differences)
		return exitCode(1)
	}
	fmt.Println("in sync")
	return nil
}

func hostWants(root, racer, key, self string) []hostWant {
	wants := []hostWant{{name: "site", address: siteName,
		machine:  ownerMachine(root, siteName, key, "site-known-hosts"),
		binaries: map[string]string{hostAgentBinary: self}, ports: []string{"22", "80", "443"},
		units: []string{"dragrace-site.service", "dragrace-site-https.socket",
			"dragrace-site-http.socket", "dragrace-host-agent.timer",
			"dragrace-site-renew.timer", "apt-daily-upgrade.timer"},
		siteDeploy: true}}
	if racer == "" {
		return wants
	}
	return append(wants, hostWant{name: "racer", address: racer,
		machine:  ownerMachine(root, racer, key, "racer-known-hosts"),
		binaries: map[string]string{guardBinary: self},
		present: []string{"/etc/dragrace-guard/config.json",
			"/etc/credstore.encrypted/digitalocean-token", "/etc/credstore.encrypted/racer-token"},
		ports: []string{"22"},
		units: []string{"dragrace-guard.service", "dragrace-racer.service",
			"dragrace-racer-check.timer", "apt-daily-upgrade.timer"},
		racerBin: true})
}

// newestRelease is the newest build's build.json (the CDN download the
// host agent reads).
func newestRelease(ctx context.Context) (BuildInfo, error) {
	var info BuildInfo
	path := filepath.Join(os.TempDir(), fmt.Sprintf("dragrace-build-%d.json", os.Getpid()))
	defer os.Remove(path)
	agent := HostAgent{config: HostConfig{Repository: "Eldhus/fourneau-dragrace"}}
	if err := httpFetch(ctx, agent.latest("build.json"), path); err != nil {
		return info, err
	}
	return info, readJSON(path, &info)
}

// probeScript prints, a line each, what the check compares but the files.
func probeScript(want hostWant) string {
	lines := []string{
		"for f in " + strings.Join(want.present, " ") + "; do sudo test -e $f || echo missing $f; done",
		"for f in " + strings.Join(hostRetired, " ") + "; do sudo test -e $f && echo retired $f; done",
		"sudo ufw status | sed -n 1p | sed 's/^/ufw /'",
		"sudo ufw status | awk '$2==\"ALLOW\" && $1!~/v6/ {print \"port\", $1}'",
		"echo partuuid $(findmnt -no PARTUUID /) $(sed -n 's/^GRUB_FORCE_PARTUUID=//p' " +
			"/etc/default/grub.d/40-force-partuuid.cfg 2>/dev/null)",
		"echo booted $(grep -c 'root=PARTUUID.*panic=-1' /proc/cmdline)",
		"for u in " + strings.Join(want.units, " ") + "; do echo active $u $(systemctl is-active $u); done",
		"systemctl --failed --plain --no-legend | awk '{print \"failed\", $1}'",
		"test -e /run/reboot-required && echo reboot-required",
	}
	if want.racerBin {
		lines = append(lines, "echo racerbin $(sudo -u racer /var/lib/dragrace-racer/bin/dragrace version 2>/dev/null)")
	}
	if want.siteDeploy {
		lines = append(lines, "echo current $(basename $(readlink "+siteHome+"/current))",
			"ls "+siteHome+"/failed 2>/dev/null | sed 's/^/failed-deploy /'")
	}
	return strings.Join(lines, "; ") + "; true"
}

// checkHost prints the host's findings; it returns how many differ.
func checkHost(ctx context.Context, root string, want hostWant, release BuildInfo) (int, error) {
	out, err := want.machine.Shell(ctx, probeScript(want))
	if err != nil {
		return 0, err
	}
	fmt.Printf("== %s %s\n", want.name, want.address)
	seen := map[string]string{}
	var lines [][]string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		lines = append(lines, fields)
		seen[fields[0]] = strings.Join(fields[1:], " ")
	}
	report := &findings{}
	if err := compareSums(ctx, report, root, want); err != nil {
		return 0, err
	}
	compareState(report, want, lines, seen)
	compareVersions(report, want, seen, release)
	return report.differ, nil
}

type findings struct{ differ int }

func (report *findings) ok(what string) { fmt.Printf("  ok    %s\n", what) }

func (report *findings) diff(format string, args ...any) {
	report.differ++
	fmt.Printf("  DIFF  %s\n", fmt.Sprintf(format, args...))
}

// compareSums compares the host's SHA256SUMS with the one this checkout and
// binary make now, then has the host check its files against it.
func compareSums(ctx context.Context, report *findings, root string, want hostWant) error {
	files, err := hostTree(root, want.name)
	if err != nil {
		return err
	}
	sums, err := hostSums(files, want.binaries)
	if err != nil {
		return err
	}
	installed, err := want.machine.Shell(ctx, "sudo cat "+sumsPath+" 2>/dev/null")
	if sshFailed(err) {
		return err
	}
	if err != nil {
		report.diff("no %s (installed before it): install again", sumsPath)
		return nil
	}
	if installed+"\n" == sums {
		report.ok(fmt.Sprintf("%s as this checkout and binary make it", sumsPath))
	} else {
		report.diff("%s is not as this checkout and binary make it: install again", sumsPath)
		wanted := strings.Split(strings.TrimSuffix(sums, "\n"), "\n")
		have := strings.Split(installed, "\n")
		for _, line := range have {
			if !slices.Contains(wanted, line) {
				fmt.Printf("        installed  %s\n", line)
			}
		}
		for _, line := range wanted {
			if !slices.Contains(have, line) {
				fmt.Printf("        wanted     %s\n", line)
			}
		}
	}
	changed, err := want.machine.Shell(ctx, "sudo sha256sum -c --quiet "+sumsPath)
	if sshFailed(err) {
		return err
	}
	if err != nil {
		report.diff("files changed since the install (sha256sum -c):")
		for _, line := range strings.Split(changed, "\n") {
			fmt.Printf("        %s\n", line)
		}
	} else {
		report.ok("each file as " + sumsPath + " lists it")
	}
	return nil
}

// sshFailed says whether ssh itself failed (its exit status 255), rather
// than the command it ran.
func sshFailed(err error) bool {
	var exit *exec.ExitError
	return err != nil && (!errors.As(err, &exit) || exit.ExitCode() == 255)
}

func compareState(report *findings, want hostWant, lines [][]string, seen map[string]string) {
	for _, fields := range lines {
		switch {
		case fields[0] == "missing" && len(fields) == 2:
			report.diff("%s is missing", fields[1])
		case fields[0] == "retired" && len(fields) == 2:
			report.diff("%s is retired but still there", fields[1])
		}
	}
	if seen["ufw"] != "Status: active" {
		report.diff("firewall: %q", seen["ufw"])
	}
	var ports []string
	for _, fields := range lines {
		if fields[0] == "port" && len(fields) == 2 {
			ports = append(ports, strings.TrimSuffix(fields[1], "/tcp"))
		}
	}
	sort.Strings(ports)
	expected := append([]string{}, want.ports...)
	sort.Strings(expected)
	if strings.Join(ports, ",") != strings.Join(expected, ",") {
		report.diff("firewall ports %v, want %v", ports, expected)
	} else if seen["ufw"] == "Status: active" {
		report.ok(fmt.Sprintf("firewall on, ports %v", ports))
	}
	parts := strings.Fields(seen["partuuid"])
	if len(parts) != 2 || parts[0] != parts[1] {
		report.diff("boot without an initramfs not set up: %q", seen["partuuid"])
	} else if seen["booted"] != "1" {
		report.diff("set up, but this boot came through the initramfs (the fallback: a failed boot?)")
	} else {
		report.ok("booted without an initramfs")
	}
	for _, fields := range lines {
		if fields[0] == "active" && len(fields) == 3 && fields[2] != "active" {
			report.diff("%s is %s", fields[1], fields[2])
		}
		if fields[0] == "failed" && len(fields) == 2 {
			report.diff("%s failed", fields[1])
		}
	}
	report.ok(fmt.Sprintf("%d units checked", len(want.units)))
	if _, pending := seen["reboot-required"]; pending {
		fmt.Println("  note  a reboot is pending (Ubuntu's next update run does it)")
	}
}

func compareVersions(report *findings, want hostWant, seen map[string]string, release BuildInfo) {
	newest := release.Commits["fourneau-dragrace"]
	if want.racerBin {
		if got := seen["racerbin"]; got != newest {
			report.diff("racer binary at %q, the newest release %s (it updates within 10 minutes, idle)",
				short(got), short(newest))
		} else {
			report.ok("racer binary at the newest release, " + short(newest))
		}
	}
	if want.siteDeploy {
		id := release.Files["site.tar.gz"]
		if len(id) >= 16 {
			id = id[:16]
		}
		if seen["current"] == id {
			report.ok("site at the newest release's site, " + id)
		} else if strings.Contains(seen["failed-deploy"], id) {
			report.diff("the newest site (%s) failed to deploy: rolled back to %s", id, seen["current"])
		} else {
			report.diff("site at %s, the newest release's is %s (the agent deploys within a minute)",
				seen["current"], id)
		}
	}
}
