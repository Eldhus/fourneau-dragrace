package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// The site host: one small droplet, up all the time, running the site (a
// roux app, site_build.go) and keeping the races in its database. In short:
//   - cook: the owner's key, sudo. Root login and passwords are off. (Not
//     "admin": Ubuntu's image has an admin group, so useradd refuses it
//     and cloud-init carries on without the user.)
//   - site: no login; runs the site from /opt/dragrace-site/current (a
//     release the host agent unpacked), in /var/lib/dragrace-site: its
//     database, its copies, its two tokens, its certificate. Sandboxed by
//     systemd, allowed to bind ports 80 and 443 and nothing more; it
//     obtains its own certificate (fourneau's ACME, through roux's host).
//   - the host agent (root, a timer, every minute): deploys the newest
//     build's site, rolling back one that does not answer.
//
// Its units and configs are files in hosts/site/ (and hosts/common/).

// siteName is the site's name (an A record): the host the installs
// and the check reach, and the one hosts/ names (the certificate's, the host
// agent's health check's, the racer's site).
const siteName = "fourneau.y2kbugger.com"

// siteHome is the site's code: releases/ID, and current, a link to one.
const siteHome = "/opt/dragrace-site"

// siteState is the site's working directory: site.db, backups/, secrets/,
// and static, a link into the current release.
const siteState = "/var/lib/dragrace-site"

// hostAgentBinary is the host agent: this dragrace binary, as installed.
const hostAgentBinary = "/usr/local/bin/dragrace-host-agent"

// siteUserData makes the users and the firewall, once. The services are
// install-server's (hosts/site/), so a host made earlier and one made today
// run the same ones.
const siteUserData = `#cloud-config
disable_root: true
ssh_pwauth: false
users:
  - name: cook
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys: ["ADMIN_KEY"]
  - name: site
    system: true
    shell: /usr/sbin/nologin
package_update: true
package_upgrade: true
packages: [sqlite3, ufw, unattended-upgrades]
runcmd:
  - ufw default deny incoming
  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable
`

func commandSite(ctx context.Context, root string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: dragrace site build|dev|provision|install-server|race-now")
	}
	switch args[0] {
	case "build":
		return siteBuildCommand(ctx, root, args[1:])
	case "dev":
		return siteDevCommand(ctx, root, args[1:])
	case "provision":
		return siteProvision(ctx, root, args[1:])
	case "install-server":
		return siteInstallServer(ctx, root, args[1:])
	case "race-now":
		return siteRaceNow(ctx, args[1:])
	}
	return fmt.Errorf("unknown: dragrace site %s", args[0])
}

// secretsDir holds what a setup made here: out/secrets, never committed
// (the hosts' pinned keys).
func secretsDir(root string) string { return filepath.Join(outDir(root), "secrets") }

// siteProvision makes the site droplet, once. It registers the owner's
// admin key with DigitalOcean (so no root password is ever emailed), and
// waits until SSH answers.
func siteProvision(ctx context.Context, root string, args []string) error {
	flags := newFlags("site provision")
	adminKey := flags.String("admin-key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa.pub"),
		"the owner's public key, for the cook user (sudo)")
	size := flags.String("size", "s-1vcpu-512mb-10gb", "droplet size")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	// In the races' region, beside the racer and the workers that post to
	// it (the first site host was in nyc3, from when GitHub's US runner
	// raced).
	host, err := provisionHost(ctx, root, hostRequest{name: "fourneau-dragrace-site",
		tag: "fourneau-dragrace-site", region: race.Cloud.Region, size: *size, adminKey: *adminKey,
		userData: siteUserData, knownHosts: "site-known-hosts"})
	if err != nil {
		return err
	}
	fmt.Printf(`
The site host is up at %s; nothing serves until install-server.

Next: %s's A record
to %s, then
  dragrace site install-server
`, host, siteName, host)
	return nil
}

// hostRequest is a 24/7 droplet of the owner's: the site host, the racer.
type hostRequest struct {
	name, tag, region, size, adminKey, userData, knownHosts string
}

func provisionHost(ctx context.Context, root string, request hostRequest) (string, error) {
	race, err := loadRace(root)
	if err != nil {
		return "", err
	}
	do, err := newDigitalOcean()
	if err != nil {
		return "", err
	}
	admin, err := os.ReadFile(request.adminKey)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(secretsDir(root), 0o700); err != nil {
		return "", err
	}
	key, err := do.ensureKey(ctx, adminKeyName, strings.TrimSpace(string(admin)))
	if err != nil {
		return "", err
	}
	userData := strings.ReplaceAll(request.userData, "ADMIN_KEY", strings.TrimSpace(string(admin)))
	droplet, err := do.createDroplet(ctx, DropletRequest{
		Name: request.name, Region: request.region, Size: request.size,
		Image: race.Cloud.Image, SSHKeys: []int{key.ID}, Tags: []string{request.tag},
		UserData: userData, Monitoring: true,
	})
	if err != nil {
		return "", err
	}
	log.Printf("droplet %d: %s; waiting for it", droplet.ID, request.name)
	droplet, err = waitActive(ctx, do, droplet.ID)
	if err != nil {
		return "", err
	}
	host := droplet.address("public")
	machine := SSHMachine{User: "cook", Host: host, Key: privateFor(request.adminKey),
		KnownHosts: filepath.Join(secretsDir(root), request.knownHosts)}
	log.Printf("%s: waiting for SSH, then the first boot (package upgrades: a few minutes)", host)
	return host, waitSSH(ctx, machine)
}

// privateFor turns ~/.ssh/id_rsa.pub into ~/.ssh/id_rsa.
func privateFor(public string) string { return strings.TrimSuffix(public, ".pub") }

// ownerMachine is a host of the owner's, as cook.
func ownerMachine(root, host, key, knownHosts string) SSHMachine {
	return SSHMachine{User: "cook", Host: host, Key: key,
		KnownHosts: filepath.Join(secretsDir(root), knownHosts)}
}

// siteInstallServer sets the site host up,
// as cook: its files (hosts/site/, hosts/common/), the host agent (this
// dragrace binary, pinned), the site's two tokens from the owner's keyring
// (made there if missing), and a first deploy. Run again after a change to
// hosts/ or the agent; never needed for a new site: a push deploys that.
func siteInstallServer(ctx context.Context, root string, args []string) error {
	flags := newFlags("site install-server")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	flags.Parse(args)
	agent, err := os.Executable()
	if err != nil {
		return err
	}
	machine := ownerMachine(root, siteName, *key, "site-known-hosts")
	if err := machine.Put(ctx, agent, "/tmp/dragrace-host-agent"); err != nil {
		return err
	}
	if err := installHost(ctx, machine, root, "site", map[string]string{hostAgentBinary: agent},
		nil); err != nil {
		return err
	}
	setup := strings.Join(append(hostSetup("22", "80", "443"),
		"sudo install -m 755 /tmp/dragrace-host-agent "+hostAgentBinary,
		"rm /tmp/dragrace-host-agent",
		"sudo install -d -m 755 "+siteHome,
		"sudo install -d -m 700 -o site -g site "+siteState+" "+siteState+"/secrets "+
			siteState+"/backups",
		"sudo ln -sfn "+siteHome+"/current/static "+siteState+"/static",
		// The first boot's dist-upgrade can outlive `cloud-init status
		// --wait`: wait for its lock.
		"sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1800 install -y -q sqlite3 >/dev/null 2>&1",
		// kTLS: the kernel loads tls only for a CAP_NET_ADMIN process; the
		// site has none, so it is loaded at boot (modules-load.d) and now.
		"sudo modprobe tls",
		"sudo systemctl daemon-reload",
		"sudo systemctl enable --now dragrace-site-renew.timer dragrace-host-agent.timer",
		// The sockets take ports 80 and 443: a site still binding them
		// itself (installed before them) stops first, then starts on them
		// (a host with no site yet skips the start: ConditionPathExists).
		"sudo systemctl stop dragrace-site.service",
		"sudo systemctl enable --now dragrace-site-https.socket dragrace-site-http.socket",
		"sudo systemctl enable dragrace-site.service",
		"sudo systemctl start dragrace-site.service",
	), " && ")
	if _, err := machine.Shell(ctx, setup); err != nil {
		return err
	}
	for _, name := range []string{"racer-token", "manual-token"} {
		token, err := keyringToken(ctx, name)
		if err != nil {
			return err
		}
		path := siteState + "/secrets/" + name
		if err := machine.ShellInput(ctx, "sudo sh -c 'umask 077; cat > "+path+
			" && chown site:site "+path+"'", token+"\n"); err != nil {
			return err
		}
	}
	log.Printf("deploying the newest build's site (the host agent)")
	if _, err := machine.Shell(ctx, "sudo systemctl start dragrace-host-agent.service; "+
		"sudo systemctl restart dragrace-site.service; sleep 3; "+
		"systemctl is-active dragrace-site.service"); err != nil {
		log.Printf("the site is not up; its log: ssh cook@%s journalctl -u dragrace-site; "+
			"the agent's: journalctl -u dragrace-host-agent", siteName)
		return err
	}
	fmt.Printf("the site is serving https://%s/\n", siteName)
	return nil
}

// hostRetired are files an install deletes: the racer's GitHub token, which
// started builds until the builds became daily, and the commit an install stamped before SHA256SUMS.
// Once `racer install` has run on a build after a5204c0, and
// both installs on one with SHA256SUMS, this and its uses (hostSetup,
// hosts.go's probe) can go.
var hostRetired = []string{
	"/etc/credstore.encrypted/github-token",
	"/etc/dragrace-host/installed",
}

// hostSetup is the script that goes with the host's files (hosts/): the
// first boot's cloud-init waited for (DigitalOcean's per-instance script
// can replace the machine id late, and the racer's credentials, encrypted
// before it, would stop decrypting at the next restart),
// sshd reloaded, the retired files gone, a 512 MiB swap file (a 512 MB
// droplet thrashed in its first boot's package checks), and Ubuntu's
// update-notifier and motd timers off (nobody logs in to read them; on the
// racer they took a CPU for minutes).
//
// And a boot without an initramfs: GRUB_FORCE_PARTUUID, Ubuntu's own
// cloud images' setting (DigitalOcean's image leaves it out). The kernel
// has virtio and ext4 built in and mounts the root partition itself; a
// failed boot falls back to the initramfs, which can panic on a 512 MB
// droplet ("No working init found", "System is deadlocked on memory").
// Only the boot changes: the initramfs is freed once the root is mounted.
//
// The firewall too: incoming refused but for `ports`. It was cloud-init's
// alone, whose final stage stops at a failed package step, leaving ufw
// inactive, while `status` says done.
func hostSetup(ports ...string) []string {
	firewall := "sudo ufw default deny incoming >/dev/null"
	for _, port := range ports {
		firewall += " && sudo ufw allow " + port + "/tcp >/dev/null"
	}
	return []string{
		"(cloud-init status --wait >/dev/null; true)",
		"sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1800 install -y -q ufw >/dev/null 2>&1",
		firewall,
		"sudo ufw --force enable >/dev/null",
		"sudo ufw status | grep -q '^Status: active'",
		"echo \"GRUB_FORCE_PARTUUID=$(findmnt -no PARTUUID /)\" | " +
			"sudo tee /etc/default/grub.d/40-force-partuuid.cfg >/dev/null",
		"grep -q '^GRUB_FORCE_PARTUUID=[0-9a-f-]\\{36\\}$' /etc/default/grub.d/40-force-partuuid.cfg",
		"sudo update-grub 2>/dev/null",
		"sudo sshd -t && sudo systemctl reload ssh",
		"sudo rm -f " + strings.Join(hostRetired, " "),
		"sudo systemctl daemon-reload",
		"(test -e /swapfile || (sudo fallocate -l 512M /swapfile && sudo chmod 600 /swapfile && " +
			"sudo mkswap -q /swapfile))",
		"(swapon --show=NAME --noheadings | grep -q /swapfile || sudo swapon /swapfile)",
		"(grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null)",
		"sudo systemctl disable --now update-notifier-download.timer update-notifier-motd.timer " +
			"motd-news.timer 2>/dev/null; true",
	}
}

// siteRaceNow asks the site for a race, with the owner's manual token.
func siteRaceNow(ctx context.Context, args []string) error {
	flags := newFlags("site race-now")
	host := flags.String("host", "", "the site host's address")
	flags.Parse(args)
	if *host == "" {
		return fmt.Errorf("-host is required")
	}
	token, err := keyringLookup(ctx, "manual-token")
	if err != nil {
		return err
	}
	var answer struct {
		ID      int64 `json:"id"`
		Already bool  `json:"already"`
	}
	site := newSiteClient("https://"+*host, token)
	if err := site.post(ctx, "/api/requests?kind=race", nil, &answer); err != nil {
		return err
	}
	if answer.Already {
		fmt.Printf("a race was asked for already (request %d); the racer takes it soon\n", answer.ID)
	} else {
		fmt.Printf("race asked for (request %d); the racer takes it within a minute\n", answer.ID)
	}
	return nil
}
