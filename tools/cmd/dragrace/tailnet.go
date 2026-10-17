package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// The owner reaches the two hosts' SSH over the owner's tailnet (Tailscale)
// alone. Each host joins it tagged with its own name (tag:dragrace-site,
// tag:dragrace-racer), a device of no user's; the tailnet's policy grants
// the tags nothing, so a host taken over reaches no other device. Its
// firewall takes port 22 on tailscale0 only. Everything else is as before:
// the site serves the public on 80 and 443, the racer reaches race droplets
// and the site over the internet. Tailscale comes from its own apt
// repository, at the version hosts/common/etc/apt/preferences.d/tailscale
// pins.
//
// A host's first install reaches it by its public address (-host): the
// install joins it with a one-off auth key (TAILSCALE_AUTH_KEY), reaches it
// again by its tailnet name, and only then closes the public port 22. Every
// install after reaches it by the name.
//
// Locked out (Tailscale down on a host, its public 22 closed): DigitalOcean's
// Droplet Console is SSH over the network, so closed too; the way in is the
// recovery ISO (power off, boot it from the panel's Recovery tab, mount the
// disk, `ufw allow 22/tcp` in a chroot or the rule in /etc/ufw/user.rules).

const (
	siteTailnetName  = "dragrace-site"
	racerTailnetName = "dragrace-racer"
)

// tailscalePin is the file that pins Tailscale's version on every host.
const tailscalePin = "hosts/common/etc/apt/preferences.d/tailscale"

// tailnetSSHRule is the firewall's one way to SSH: from the tailnet.
const tailnetSSHRule = "allow in on tailscale0 to any port 22 proto tcp"

// publicSSHRule is the rule a droplet is made with (hosts/*.cloud-init.yaml)
// and the first install removes.
const publicSSHRule = "allow 22/tcp"

// firewallRules are a host's rules, as `ufw show added` lists them: its
// public ports, and SSH from the tailnet.
func firewallRules(public ...string) []string {
	var rules []string
	for _, port := range public {
		rules = append(rules, "allow "+port+"/tcp")
	}
	return append(rules, tailnetSSHRule)
}

// tailscaleVersion is the version tailscalePin pins.
func tailscaleVersion(root string) (string, error) {
	bytes, err := os.ReadFile(filepath.Join(root, tailscalePin))
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(bytes), "\n") {
		if version, found := strings.CutPrefix(line, "Pin: version "); found {
			return strings.TrimSpace(version), nil
		}
	}
	return "", fmt.Errorf("%s pins no version", tailscalePin)
}

// tailscaleStatus is what the install and the check read of
// `tailscale status --json`.
type tailscaleStatus struct {
	BackendState string
	Self         struct {
		DNSName string
		Tags    []string
	}
}

func readTailscaleStatus(ctx context.Context, machine SSHMachine) (tailscaleStatus, error) {
	var status tailscaleStatus
	out, err := machine.Shell(ctx, "sudo tailscale status --json")
	if sshFailed(err) {
		return status, err
	}
	// Logged out, the command fails but still prints its state.
	if err := json.Unmarshal([]byte(out), &status); err != nil {
		return status, fmt.Errorf("tailscale status: %w", err)
	}
	return status, nil
}

// joined says whether the host is on the tailnet as name, with its tag.
func (status tailscaleStatus) joined(name string) error {
	if status.BackendState != "Running" {
		return fmt.Errorf("tailscale is %q, not Running", status.BackendState)
	}
	if !strings.HasPrefix(status.Self.DNSName, name+".") {
		return fmt.Errorf("on the tailnet as %q, not %s (another device has the name?)",
			status.Self.DNSName, name)
	}
	if !slices.Equal(status.Self.Tags, []string{"tag:" + name}) {
		return fmt.Errorf("tagged %v, not tag:%s alone", status.Self.Tags, name)
	}
	return nil
}

// joinTailnet puts the host on the tailnet as name, if it is not, pins its
// host keys under the name, reaches it by the name, and closes its public
// SSH; it returns the machine by the name. The keys pinned are the ones
// already trusted for machine.Host: nothing is trusted anew.
func joinTailnet(ctx context.Context, root string, machine SSHMachine, name string) (SSHMachine, error) {
	status, err := readTailscaleStatus(ctx, machine)
	if err != nil {
		return machine, err
	}
	if status.joined(name) != nil {
		key := strings.TrimSpace(os.Getenv("TAILSCALE_AUTH_KEY"))
		if key == "" {
			return machine, fmt.Errorf("%s is not on the tailnet as %s (%v): set TAILSCALE_AUTH_KEY "+
				"to a one-off auth key tagged tag:%s", machine.Host, name, status.joined(name), name)
		}
		log.Printf("joining the tailnet as %s", name)
		up := "sudo tailscale up --auth-key=file:/dev/stdin --hostname=" + name +
			" --advertise-tags=tag:" + name + " --accept-dns=false --accept-routes=false --ssh=false"
		if err := machine.ShellInput(ctx, up, key+"\n"); err != nil {
			return machine, fmt.Errorf("tailscale up: %w", err)
		}
		if status, err = readTailscaleStatus(ctx, machine); err != nil {
			return machine, err
		}
		if err := status.joined(name); err != nil {
			return machine, err
		}
	}
	if _, err := machine.Shell(ctx, "sudo tailscale set --auto-update=false --webclient=false"); err != nil {
		return machine, err
	}
	byName := machine
	byName.Host = name
	if machine.Host != name {
		if err := pinUnder(machine.KnownHosts, machine.Host, name); err != nil {
			return machine, err
		}
	}
	reached := false
	for wait := 0; wait < 12 && !reached; wait++ {
		if wait > 0 {
			if err := sleepContext(ctx, 5*time.Second); err != nil {
				return machine, err
			}
		}
		_, err := byName.Shell(ctx, "true")
		reached = err == nil
	}
	if !reached {
		return machine, fmt.Errorf("%s is on the tailnet but not reached as %s from here in a minute: "+
			"its public SSH stays open", machine.Host, name)
	}
	closePublic := "if sudo ufw show added | grep -qxF " + quote("ufw "+publicSSHRule) +
		"; then sudo ufw delete " + publicSSHRule + " >/dev/null; fi"
	if _, err := byName.Shell(ctx, closePublic); err != nil {
		return machine, err
	}
	return byName, nil
}

// pinUnder gives name, in a known_hosts file, the keys the file holds for
// host, in place of any it had.
func pinUnder(knownHosts, host, name string) error {
	bytes, err := os.ReadFile(knownHosts)
	if err != nil {
		return err
	}
	var kept, keys []string
	for _, line := range strings.Split(strings.TrimSpace(string(bytes)), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			kept = append(kept, line)
			continue
		}
		names := strings.Split(fields[0], ",")
		if slices.Contains(names, host) {
			keys = append(keys, name+" "+strings.Join(fields[1:], " "))
		}
		if !slices.Contains(names, name) {
			kept = append(kept, line)
		}
	}
	if len(keys) == 0 {
		return fmt.Errorf("%s holds no key for %s", knownHosts, host)
	}
	return os.WriteFile(knownHosts, []byte(strings.Join(append(kept, keys...), "\n")+"\n"), 0o600)
}
