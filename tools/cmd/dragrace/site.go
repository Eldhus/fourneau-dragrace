package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The site host: one small droplet, up all the time, running the site (a
// roux app, site_build.go) and keeping the races in its database
// (docs/self-hosting.md; SECURITY.md has the setup). In short:
//   - cook: the owner's key, sudo. Root login and passwords are off. (Not
//     "admin": Ubuntu's image has an admin group, so useradd refuses it
//     and cloud-init carries on without the user; 2026-10-06.)
//   - site: no login; runs the site from /opt/dragrace-site/current (a
//     release the host agent unpacked), in /var/lib/dragrace-site: its
//     database, its copies, its two tokens, its certificate. Sandboxed by
//     systemd, allowed to bind ports 80 and 443 and nothing more; it
//     obtains its own certificate (fourneau's ACME, through roux's host).
//   - the host agent (root, a timer, every minute): deploys the newest
//     build's site, rolling back one that does not answer.

// siteHome is the site's code: releases/ID, and current, a link to one.
const siteHome = "/opt/dragrace-site"

// siteState is the site's working directory: site.db, backups/, secrets/,
// and static, a link into the current release.
const siteState = "/var/lib/dragrace-site"

// siteUserData makes the users and the firewall, once. The services are
// install-server's (siteUnits), so a host made earlier and one made today
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

// The ACME directories install-server can point the site at: staging to
// try (its certificates are not trusted by browsers), production after.
var acmeDirectories = map[string]string{
	"staging":    "https://acme-staging-v02.api.letsencrypt.org/directory",
	"production": "https://acme-v02.api.letsencrypt.org/directory",
}

// siteUnits are the site's systemd units and the kernel modules it needs:
// the site on 443 with its own certificate (ACME, for the host's IP
// address, Let's Encrypt's six-day profile) and port 80 redirecting; a
// daily restart, which renews the certificate when a third of its life is
// left (fourneau's acme.zig); the host agent's timer.
func siteUnits(host, acmeDirectory string) map[string]string {
	service := `[Unit]
Description=the dragrace site (roux)
After=network-online.target
Wants=network-online.target
ConditionPathExists={site_home}/current/dragrace-site
[Service]
User=site
StateDirectory=dragrace-site
StateDirectoryMode=0700
WorkingDirectory={site_state}
Environment=ROUX_ADDRESS=0.0.0.0
Environment=ROUX_REDIRECT_PORT=80
Environment=ROUX_ACME_DIRECTORY={acme_directory}
Environment=ROUX_ACME_IDENTIFIER={host}
Environment=ROUX_ACME_STATE={site_state}
Environment=ROUX_ACME_PROFILE=shortlived
ExecStart={site_home}/current/dragrace-site
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
LimitNOFILE=65536
MemoryMax=256M
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
`
	// Braced placeholders: a bare ACME_DIRECTORY also matched inside
	// ROUX_ACME_DIRECTORY, and the site would not start (2026-10-06).
	service = strings.NewReplacer("{site_home}", siteHome, "{site_state}", siteState,
		"{acme_directory}", acmeDirectory, "{host}", host).Replace(service)
	return map[string]string{
		"/etc/systemd/system/dragrace-site.service": service,
		"/etc/systemd/system/dragrace-site-renew.service": `[Unit]
Description=Restart the site, which renews its certificate when due
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart dragrace-site.service
`,
		"/etc/systemd/system/dragrace-site-renew.timer": `[Unit]
Description=Daily: restart the site, which renews its certificate when due
[Timer]
OnCalendar=*-*-* 04:17:00
RandomizedDelaySec=30m
Persistent=true
Unit=dragrace-site-renew.service
[Install]
WantedBy=timers.target
`,
		"/etc/systemd/system/dragrace-host-agent.service": `[Unit]
Description=Deploy the newest build's site (docs/self-hosting.md)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/dragrace-host-agent host-agent
TimeoutStartSec=15min
`,
		"/etc/systemd/system/dragrace-host-agent.timer": `[Unit]
Description=Every minute: deploy the newest build's site
[Timer]
OnBootSec=1min
OnUnitInactiveSec=1min
[Install]
WantedBy=timers.target
`,
		// kTLS: the kernel loads tls only for a CAP_NET_ADMIN process;
		// the site has none, so it is loaded at boot.
		"/etc/modules-load.d/fourneau-tls.conf": "tls\n",
	}
}

func commandSite(ctx context.Context, root string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: dragrace site build|dev|provision|install-server|race-now|backups|restore")
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
	case "backups":
		return siteBackups(ctx, args[1:])
	case "restore":
		return siteRestore(ctx, args[1:])
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
	// raced; moved 2026-10-07).
	host, err := provisionHost(ctx, root, hostRequest{name: "fourneau-dragrace-site",
		tag: "fourneau-dragrace-site", region: race.Cloud.Region, size: *size, adminKey: *adminKey,
		userData: siteUserData, knownHosts: "site-known-hosts"})
	if err != nil {
		return err
	}
	fmt.Printf(`
The site host is up at %s; nothing serves until install-server.

Next, as SECURITY.md says:
  dragrace site install-server -host %s
`, host, host)
	return nil
}

// hostRequest is a 24/7 droplet of the owner's: the site host, the racer.
type hostRequest struct {
	name, tag, region, size, adminKey, userData, knownHosts string
}

func provisionHost(ctx context.Context, root string, request hostRequest) (string, error) {
	versions, err := loadVersions(root)
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
	key, err := do.ensureKey(ctx, "fourneau-dragrace-admin", strings.TrimSpace(string(admin)))
	if err != nil {
		return "", err
	}
	userData := strings.ReplaceAll(request.userData, "ADMIN_KEY", strings.TrimSpace(string(admin)))
	droplet, err := do.createDroplet(ctx, DropletRequest{
		Name: request.name, Region: request.region, Size: request.size,
		Image: versions.DropletImage, SSHKeys: []int{key.ID}, Tags: []string{request.tag},
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

// siteHostConfig is the host agent's config, as the install writes it.
func siteHostConfig(host string) (string, error) {
	config, err := json.MarshalIndent(HostConfig{Repository: "Eldhus/fourneau-dragrace",
		Home: siteHome, Service: "dragrace-site.service",
		Health: "https://" + host + "/api/health"}, "", "  ")
	return string(config), err
}

// siteInstallServer sets the site host up as docs/self-hosting.md says,
// as cook: the units, the host agent (this dragrace binary, pinned) and
// its config, the site's two tokens from the owner's keyring (made there
// if missing), and a first deploy. Run again after a change to the units
// or the agent; never needed for a new site: a push deploys that.
func siteInstallServer(ctx context.Context, root string, args []string) error {
	flags := newFlags("site install-server")
	host := flags.String("host", "", "the site host's address (and the certificate's)")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	// Production by default: the site is live, and an install without the
	// flag put an untrusted staging certificate on it (2026-10-06).
	acme := flags.String("acme", "production", "Let's Encrypt: production, or staging to try")
	flags.Parse(args)
	if *host == "" {
		return fmt.Errorf("-host is required")
	}
	directory, known := acmeDirectories[*acme]
	if !known {
		return fmt.Errorf("-acme: staging or production, not %q", *acme)
	}
	agent, err := os.Executable()
	if err != nil {
		return err
	}
	machine := ownerMachine(root, *host, *key, "site-known-hosts")
	config, err := siteHostConfig(*host)
	if err != nil {
		return err
	}
	stamp, err := installStamp(ctx, root)
	if err != nil {
		return err
	}
	if err := machine.Put(ctx, agent, "/tmp/dragrace-host-agent"); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, siteUnits(*host, directory), 0o644); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, map[string]string{
		"/etc/dragrace-host/config.json": config, installedPath: stamp}, 0o644); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, hostFiles(), 0o644); err != nil {
		return err
	}
	setup := strings.Join(append(hostSetup("22", "80", "443"),
		"sudo install -m 755 /tmp/dragrace-host-agent /usr/local/bin/dragrace-host-agent",
		"rm /tmp/dragrace-host-agent",
		// The layout before self-hosting: the rrsync deploy user and its data.
		"(id deploy >/dev/null 2>&1 && sudo userdel -r deploy || true)",
		"sudo rm -rf /srv/dragrace",
		"(test -L "+siteHome+"/current || sudo rm -rf "+siteHome+")",
		"sudo install -d -m 755 "+siteHome,
		"sudo install -d -m 700 -o site -g site "+siteState+" "+siteState+"/secrets "+
			siteState+"/backups",
		"sudo ln -sfn "+siteHome+"/current/static "+siteState+"/static",
		// The first boot's dist-upgrade can outlive `cloud-init status
		// --wait` (found on the rebuild of 2026-10-08): wait for its lock.
		"sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1800 install -y -q sqlite3 >/dev/null 2>&1",
		"sudo modprobe tls",
		"sudo systemctl daemon-reload",
		"sudo systemctl enable --now dragrace-site-renew.timer dragrace-host-agent.timer",
		"sudo systemctl enable dragrace-site.service",
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
			"the agent's: journalctl -u dragrace-host-agent", *host)
		return err
	}
	fmt.Printf("the site is serving https://%s/ (Let's Encrypt %s)\n", *host, *acme)
	return nil
}

// hostFiles are what every host of the owner's (the site host, the racer)
// is set up with, found missing on the first live audit (2026-10-07):
// root's login refused outright (cloud-init's disable_root only gave root
// a key that prints "login as ..."), and a reboot when an update needs one.
//
// The updates are Ubuntu's own, stock (owner, 2026-10-08, after a
// homemade reboot timer's night ended in a kernel panic on the site host;
// DigitalOcean's and Canonical's advice): unattended-upgrades' daily run,
// security only, at 06:00 UTC plus up to an hour, and its own reboot at
// the end of the run when an update needs one: so never mid-install, and
// over by 03:30 New York time at the latest, before the 05:00 race.
// Automatic-Reboot is the one setting changed (Ubuntu ships it off).
func hostFiles() map[string]string {
	return map[string]string{
		"/etc/ssh/sshd_config.d/10-dragrace.conf": "PermitRootLogin no\nPasswordAuthentication no\n",
		"/etc/apt/apt.conf.d/52dragrace-reboot": "// Reboot at the end of the update run when an update needs it (docs/self-hosting.md).\n" +
			"Unattended-Upgrade::Automatic-Reboot \"true\";\n",
	}
}

// hostRetired are the 2026-10-07 reboot timer's files, deleted by an
// install: the timer, its service, and the moved update time.
var hostRetired = []string{
	"/etc/systemd/system/dragrace-reboot.timer",
	"/etc/systemd/system/dragrace-reboot.service",
	"/etc/systemd/system/apt-daily-upgrade.timer.d/10-dragrace.conf",
}

// hostSetup is the script that goes with hostFiles: the first boot's
// cloud-init waited for (DigitalOcean's per-instance script can replace
// the machine id late, and the racer's credentials, encrypted before it,
// stopped decrypting at the next restart: found 2026-10-07), sshd
// reloaded, the retired reboot timer gone, a 512 MiB swap file (a 512 MB droplet thrashed in its
// first boot's package checks), and Ubuntu's update-notifier and motd
// timers off (nobody logs in to read them; on the racer they took a CPU
// for minutes).
//
// And a boot without an initramfs: GRUB_FORCE_PARTUUID, Ubuntu's own
// cloud images' setting (DigitalOcean's image leaves it out). The kernel
// has virtio and ext4 built in and mounts the root partition itself; a
// failed boot falls back to the initramfs. The site host's first reboot
// on 7.0.0-38 (2026-10-08) panicked twice in its initramfs ("No working
// init found", "System is deadlocked on memory"); a 512 MB droplet of the
// same image and kernel booted 4 of 4 with it and 3 of 3 without it.
// Only the boot changes: the initramfs is freed once the root is mounted.
//
// The firewall too: incoming refused but for `ports`. It was cloud-init's
// alone, whose final stage stops at a failed package step (the rebuild of
// 2026-10-08 came up with ufw inactive) while `status` says done.
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
		"(sudo systemctl disable --now dragrace-reboot.timer 2>/dev/null; true)",
		"sudo rm -f " + strings.Join(hostRetired, " "),
		"(sudo rmdir /etc/systemd/system/apt-daily-upgrade.timer.d 2>/dev/null; true)",
		"sudo systemctl daemon-reload",
		"sudo systemctl restart apt-daily-upgrade.timer",
		"(test -e /swapfile || (sudo fallocate -l 512M /swapfile && sudo chmod 600 /swapfile && " +
			"sudo mkswap -q /swapfile))",
		"(swapon --show=NAME --noheadings | grep -q /swapfile || sudo swapon /swapfile)",
		"(grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null)",
		"sudo systemctl disable --now update-notifier-download.timer update-notifier-motd.timer " +
			"motd-news.timer 2>/dev/null; true",
	}
}

// putFiles copies each file to /tmp and installs it in place as root.
func putFiles(ctx context.Context, machine SSHMachine, files map[string]string, mode os.FileMode) error {
	dir, err := os.MkdirTemp("", "dragrace-files-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	var script []string
	// Numbered: two files of one name (the guard's and the racer's
	// config.json) would take each other's place (found 2026-10-07).
	index := 0
	for path, content := range files {
		index++
		name := fmt.Sprintf("dragrace-%d-%s", index, filepath.Base(path))
		local := filepath.Join(dir, name)
		if err := os.WriteFile(local, []byte(content), 0o600); err != nil {
			return err
		}
		remote := "/tmp/" + name
		if err := machine.Put(ctx, local, remote); err != nil {
			return err
		}
		script = append(script, fmt.Sprintf("sudo install -D -m %o %s %s && rm %s", mode, remote,
			path, remote))
	}
	_, err = machine.Shell(ctx, strings.Join(script, " && "))
	return err
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

// siteBackups turns on DigitalOcean's backups of the site host, with the
// owner's token: the copy of the whole disk beside the site's own nightly
// copies. DigitalOcean's default plan is daily, seven kept, 30% of the
// droplet's price (checked 2026-10-07: its backup policy endpoint).
func siteBackups(ctx context.Context, args []string) error {
	flags := newFlags("site backups")
	flags.Parse(args)
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	droplets, err := do.dropletsTagged(ctx, "fourneau-dragrace-site")
	if err != nil {
		return err
	}
	if len(droplets) != 1 {
		return fmt.Errorf("%d droplets tagged fourneau-dragrace-site, want 1", len(droplets))
	}
	return do.enableBackups(ctx, droplets[0].ID)
}

// siteRestore puts one of DigitalOcean's backups in place of the site
// host's disk, with the owner's token. Without -backup it lists them and
// restores nothing. Written when the site host's reboot of 2026-10-08
// came up to a kernel panic; afterwards, `site install-server` again
// (what the backup's disk predates). The database loses what was written
// after the backup.
func siteRestore(ctx context.Context, args []string) error {
	flags := newFlags("site restore")
	backup := flags.Int("backup", 0, "the backup's id (none: list them)")
	flags.Parse(args)
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	droplets, err := do.dropletsTagged(ctx, "fourneau-dragrace-site")
	if err != nil {
		return err
	}
	if len(droplets) != 1 {
		return fmt.Errorf("%d droplets tagged fourneau-dragrace-site, want 1", len(droplets))
	}
	backups, err := do.backups(ctx, droplets[0].ID)
	if err != nil {
		return err
	}
	if *backup == 0 {
		for _, each := range backups {
			fmt.Printf("%d  %s  %s\n", each.ID, each.CreatedAt, each.Name)
		}
		return nil
	}
	known := false
	for _, each := range backups {
		known = known || each.ID == *backup
	}
	if !known {
		return fmt.Errorf("-backup %d is not one of droplet %d's backups", *backup, droplets[0].ID)
	}
	action, err := do.restore(ctx, droplets[0].ID, *backup)
	if err != nil {
		return err
	}
	log.Printf("restoring droplet %d from backup %d (action %d)", droplets[0].ID, *backup, action)
	for range restoreChecksMax {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(15 * time.Second):
		}
		status, err := do.actionStatus(ctx, action)
		if err != nil {
			return err
		}
		switch status {
		case "completed":
			fmt.Printf("restored; next: dragrace site install-server -host <site>\n")
			return nil
		case "errored":
			return fmt.Errorf("the restore (action %d) errored", action)
		}
	}
	return fmt.Errorf("the restore (action %d) is not done after %d checks", action, restoreChecksMax)
}

const restoreChecksMax = 160 // 15 s apart: 40 minutes
