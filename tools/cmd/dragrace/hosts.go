package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// `dragrace hosts check`: the two hosts against this checkout, read only.
// The boxes are set up by `site install-server` and `racer install`, which
// push what the code says and record nothing; a firewall off and a check
// that could never run went unseen until a rebuild (2026-10-08). Each
// install now stamps its commit on the box, and the check renders what
// the code says should be there and compares: every unit and host file
// by hash, the firewall's ports, the boot without an initramfs, the
// retired files gone, the services up, no unit failed, a reboot pending,
// the stamp against HEAD, and each binary that updates itself (the site,
// the racer) against the newest release. It prints each finding and
// exits 1 on any difference.

// installedPath is where an install stamps its commit.
const installedPath = "/etc/dragrace-host/installed"

// installStamp is the commit this checkout is at ("-dirty" with changes
// not committed) and the time: what the install pushes is that tree.
func installStamp(ctx context.Context, root string) (string, error) {
	head, err := exec.CommandContext(ctx, "git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("the install's commit: %w", err)
	}
	commit := strings.TrimSpace(string(head))
	status, err := exec.CommandContext(ctx, "git", "-C", root, "status", "--porcelain").Output()
	if err != nil {
		return "", err
	}
	if len(strings.TrimSpace(string(status))) > 0 {
		commit += "-dirty"
	}
	return fmt.Sprintf("commit %s\ninstalled %s\n", commit,
		time.Now().UTC().Format(time.RFC3339)), nil
}

// hostWant is what one host should be, by this checkout.
type hostWant struct {
	name       string
	machine    SSHMachine
	files      map[string]string // path: content, compared by SHA-256
	present    []string          // paths whose content varies (prices, secrets): there
	ports      []string
	units      []string // services and timers, active
	racerBin   bool     // the racer's own binary, updated from releases
	siteDeploy bool     // the site's code, deployed from releases
}

func commandHosts(ctx context.Context, root string, args []string) error {
	if len(args) == 0 || args[0] != "check" {
		return fmt.Errorf("usage: dragrace hosts check -site HOST -racer HOST")
	}
	flags := newFlags("hosts check")
	site := flags.String("site", "fourneau.y2kbugger.com", "the site host's address")
	racer := flags.String("racer", "", "the racer's address (none: the site host alone)")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	flags.Parse(args[1:])
	head, err := installStamp(ctx, root)
	if err != nil {
		return err
	}
	release, err := newestRelease(ctx)
	if err != nil {
		return err
	}
	wants, err := hostWants(root, *site, *racer, *key)
	if err != nil {
		return err
	}
	differences := 0
	for _, want := range wants {
		found, err := checkHost(ctx, want, stampCommit(head), release)
		if err != nil {
			return fmt.Errorf("%s: %w", want.name, err)
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

func hostWants(root, site, racer, key string) ([]hostWant, error) {
	config, err := siteHostConfig(site)
	if err != nil {
		return nil, err
	}
	siteFiles := siteUnits(site, acmeDirectories["production"])
	siteFiles["/etc/dragrace-host/config.json"] = config
	for path, content := range hostFiles() {
		siteFiles[path] = content
	}
	wants := []hostWant{{name: "site " + site, machine: ownerMachine(root, site, key, "site-known-hosts"),
		files: siteFiles, ports: []string{"22", "80", "443"},
		units: []string{"dragrace-site.service", "dragrace-host-agent.timer",
			"dragrace-site-renew.timer", "apt-daily-upgrade.timer"},
		siteDeploy: true}}
	if racer == "" {
		return wants, nil
	}
	racerFiles := racerUnits()
	for path, content := range hostFiles() {
		racerFiles[path] = content
	}
	return append(wants, hostWant{name: "racer " + racer,
		machine: ownerMachine(root, racer, key, "racer-known-hosts"),
		files:   racerFiles,
		present: []string{"/etc/dragrace-guard/config.json", "/etc/dragrace-racer/config.json",
			"/etc/credstore.encrypted/digitalocean-token", "/etc/credstore.encrypted/racer-token",
			"/etc/credstore.encrypted/github-token", "/usr/local/bin/dragrace-guard"},
		ports: []string{"22"},
		units: []string{"dragrace-guard.service", "dragrace-racer.service",
			"dragrace-racer-check.timer", "apt-daily-upgrade.timer"},
		racerBin: true}), nil
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

// sameTools says whether tools/, all an install pushes, is the same at
// both commits (a dirty stamp never is).
func sameTools(stamp, head string) bool {
	if strings.HasSuffix(stamp, "-dirty") || strings.HasSuffix(head, "-dirty") {
		return false
	}
	return exec.Command("git", "diff", "--quiet", stamp, head, "--", "tools").Run() == nil
}

func stampCommit(stamp string) string {
	first, _, _ := strings.Cut(stamp, "\n")
	return strings.TrimPrefix(first, "commit ")
}

// probeScript prints, a line each, what the check compares.
func probeScript(want hostWant) string {
	var paths []string
	for path := range want.files {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	all := append(append([]string{}, paths...), want.present...)
	lines := []string{
		"for f in " + strings.Join(all, " ") + "; do sudo test -e $f || echo missing $f; done",
		"sudo sha256sum " + strings.Join(paths, " ") + " 2>/dev/null | awk '{print \"sha\", $1, $2}'",
		"for f in " + strings.Join(hostRetired, " ") + " /etc/systemd/system/apt-daily-upgrade.timer.d; " +
			"do sudo test -e $f && echo retired $f; done",
		"sudo ufw status | sed -n 1p | sed 's/^/ufw /'",
		"sudo ufw status | awk '$2==\"ALLOW\" && $1!~/v6/ {print \"port\", $1}'",
		"echo partuuid $(findmnt -no PARTUUID /) $(sed -n 's/^GRUB_FORCE_PARTUUID=//p' " +
			"/etc/default/grub.d/40-force-partuuid.cfg 2>/dev/null)",
		"echo booted $(grep -c 'root=PARTUUID.*panic=-1' /proc/cmdline)",
		"for u in " + strings.Join(want.units, " ") + "; do echo active $u $(systemctl is-active $u); done",
		"systemctl --failed --plain --no-legend | awk '{print \"failed\", $1}'",
		"test -e /run/reboot-required && echo reboot-required",
		"sudo cat " + installedPath + " 2>/dev/null | sed -n 1p | sed 's/^commit /stamp /'",
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
func checkHost(ctx context.Context, want hostWant, head string, release BuildInfo) (int, error) {
	out, err := want.machine.Shell(ctx, probeScript(want))
	if err != nil {
		return 0, err
	}
	fmt.Printf("== %s\n", want.name)
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
	compareFiles(report, want, lines)
	compareState(report, want, lines, seen)
	compareVersions(report, want, seen, head, release)
	return report.differ, nil
}

type findings struct{ differ int }

func (report *findings) ok(what string) { fmt.Printf("  ok    %s\n", what) }

func (report *findings) diff(format string, args ...any) {
	report.differ++
	fmt.Printf("  DIFF  %s\n", fmt.Sprintf(format, args...))
}

func compareFiles(report *findings, want hostWant, lines [][]string) {
	hashes := map[string]string{}
	for _, fields := range lines {
		switch {
		case fields[0] == "missing" && len(fields) == 2:
			report.diff("%s is missing", fields[1])
		case fields[0] == "retired" && len(fields) == 2:
			report.diff("%s is retired but still there", fields[1])
		case fields[0] == "sha" && len(fields) == 3:
			hashes[fields[2]] = fields[1]
		}
	}
	same := 0
	for path, content := range want.files {
		sum := sha256.Sum256([]byte(content))
		if got, ok := hashes[path]; ok && got != hex.EncodeToString(sum[:]) {
			report.diff("%s differs from the code", path)
		} else if ok {
			same++
		}
	}
	report.ok(fmt.Sprintf("%d of %d files as the code says", same, len(want.files)))
}

func compareState(report *findings, want hostWant, lines [][]string, seen map[string]string) {
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

func compareVersions(report *findings, want hostWant, seen map[string]string, head string, release BuildInfo) {
	switch stamp := seen["stamp"]; {
	case stamp == "":
		report.diff("no install stamp (installed before stamps: run the install)")
	case stamp != head && !sameTools(stamp, head):
		report.diff("installed from %s; tools/ has changed since, at %s", short(stamp), short(head))
	case stamp != head:
		report.ok(fmt.Sprintf("installed from %s; tools/ unchanged since (at %s)", short(stamp), short(head)))
	default:
		report.ok("installed from this checkout's commit, " + short(head))
	}
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
