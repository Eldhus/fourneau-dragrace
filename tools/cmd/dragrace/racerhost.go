package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// The racer host (docs/self-hosting.md, "Machines"): a small droplet in
// the race region, with no inbound port but the owner's SSH. Users:
//   - cook: the owner's key, sudo;
//   - guard: runs `dragrace-guard guard` (a copy of this binary the owner
//     installs, never updated by a build), the only reader of the
//     DigitalOcean token (an encrypted systemd credential);
//   - racer: runs `dragrace racer serve` from its state directory, a binary
//     it updates itself from the newest build; reaches DigitalOcean only
//     through the guard's socket (group racer).

const racerUserData = `#cloud-config
disable_root: true
ssh_pwauth: false
users:
  - name: cook
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys: ["ADMIN_KEY"]
  - name: racer
    system: true
    shell: /usr/sbin/nologin
  - name: guard
    system: true
    shell: /usr/sbin/nologin
package_update: true
package_upgrade: true
packages: [ufw, unattended-upgrades]
runcmd:
  - ufw default deny incoming
  - ufw allow 22/tcp
  - ufw --force enable
`

// racerUnits are the guard's and the racer's services, and the 05:00 check:
// at least 90 minutes after Ubuntu's update run and its reboot (06:00 to
// 07:30 UTC, the hosts' clock), all year (owner, 2026-10-08; it was 03:00,
// inside that window in summer).
func racerUnits() map[string]string {
	return map[string]string{
		"/etc/systemd/system/dragrace-guard.service": `[Unit]
Description=the guard: the DigitalOcean token and the budget (docs/self-hosting.md)
After=network-online.target
Wants=network-online.target
[Service]
User=guard
Group=racer
LoadCredentialEncrypted=digitalocean-token
RuntimeDirectory=dragrace-guard
RuntimeDirectoryMode=0750
StateDirectory=dragrace-guard
StateDirectoryMode=0700
ExecStart=/usr/local/bin/dragrace-guard guard
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
`,
		"/etc/systemd/system/dragrace-racer.service": `[Unit]
Description=the racer: the site's requests, raced (docs/self-hosting.md)
After=network-online.target dragrace-guard.service
Wants=network-online.target
[Service]
User=racer
LoadCredentialEncrypted=racer-token
LoadCredentialEncrypted=github-token
StateDirectory=dragrace-racer
StateDirectoryMode=0700
ExecStart=/var/lib/dragrace-racer/bin/dragrace racer serve
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
`,
		"/etc/systemd/system/dragrace-racer-check.service": `[Unit]
Description=Ask the site for a check: race tonight if anything is new
[Service]
Type=oneshot
User=racer
LoadCredentialEncrypted=racer-token
ExecStart=/var/lib/dragrace-racer/bin/dragrace racer check
`,
		"/etc/systemd/system/dragrace-racer-check.timer": `[Unit]
Description=05:00 New York time: the nightly check, after Ubuntu's updates and reboot
[Timer]
OnCalendar=*-*-* 05:00:00 America/New_York
Persistent=true
[Install]
WantedBy=timers.target
`,
	}
}

// racerProvision makes the racer droplet, once, with the owner's token.
func racerProvision(ctx context.Context, root string, args []string) error {
	flags := newFlags("racer provision")
	adminKey := flags.String("admin-key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa.pub"),
		"the owner's public key, for the cook user (sudo)")
	// 1 GB, as the site host's (siteProvision): 512 MB does not boot reliably.
	size := flags.String("size", "s-1vcpu-1gb", "droplet size")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	host, err := provisionHost(ctx, root, hostRequest{name: "fourneau-dragrace-racer",
		tag: "fourneau-dragrace-racer", region: race.Cloud.Region, size: *size,
		adminKey: *adminKey, userData: racerUserData, knownHosts: "racer-known-hosts"})
	if err != nil {
		return err
	}
	fmt.Printf("\nThe racer is up at %s. Next (SECURITY.md):\n  dragrace racer install -host %s -site SITE_ADDRESS\n",
		host, host)
	return nil
}

// guardConfigFor allows race.json's sizes, each at up to a quarter above
// its price today, in race.json's region and image.
func guardConfigFor(race Race, prices map[string]float64, capUSD float64) GuardConfig {
	config := GuardConfig{Region: race.Cloud.Region, Image: race.Cloud.Image, Tag: race.Cloud.Tag,
		Sizes: map[string]float64{}, MonthlyCapUSD: capUSD, DropletsMax: 6,
		AgeMaxMinutes: race.Cloud.MaxAgeMinutes, Socket: "/run/dragrace-guard/guard.sock",
		Ledger: "/var/lib/dragrace-guard/ledger.json"}
	for _, class := range race.Cloud.Servers {
		for _, size := range []string{class.Size, class.LoaderSize} {
			config.Sizes[size] = math.Ceil(prices[size]*1.25*10000) / 10000
		}
	}
	return config
}

// racerInstall sets the racer up, as cook: the guard (this binary, pinned)
// and its config, the racer's first binary and config, the units, and the
// three secrets as encrypted credentials, each sent on SSH's standard
// input: the DigitalOcean token (DIGITALOCEAN_TOKEN, from the keyring), and
// the racer and GitHub tokens from the keyring.
func racerInstall(ctx context.Context, root string, args []string) error {
	flags := newFlags("racer install")
	host := flags.String("host", "", "the racer's address")
	siteHost := flags.String("site", "", "the site host's address")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	capUSD := flags.Float64("cap", 25, "the most the races may cost in a month, US dollars")
	flags.Parse(args)
	if *host == "" || *siteHost == "" {
		return fmt.Errorf("-host and -site are required")
	}
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	prices, err := checkSizes(ctx, do, race.Cloud)
	if err != nil {
		return err
	}
	guardConfig := guardConfigFor(race, prices, *capUSD)
	if err := guardConfig.check(); err != nil {
		return err
	}
	guardJSON, err := json.MarshalIndent(guardConfig, "", "  ")
	if err != nil {
		return err
	}
	racerJSON, err := json.MarshalIndent(RacerConfig{Site: "https://" + *siteHost,
		Guard: guardConfig.Socket, Repository: "Eldhus/fourneau-dragrace", Workflow: "build.yml",
		State: "/var/lib/dragrace-racer"}, "", "  ")
	if err != nil {
		return err
	}
	racerToken, err := keyringToken(ctx, "racer-token")
	if err != nil {
		return err
	}
	githubToken, err := keyringLookup(ctx, "github-token")
	if err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	machine := ownerMachine(root, *host, *key, "racer-known-hosts")
	if err := machine.Put(ctx, self, "/tmp/dragrace"); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, racerUnits(), 0o644); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, map[string]string{
		"/etc/dragrace-guard/config.json": string(guardJSON),
		"/etc/dragrace-racer/config.json": string(racerJSON)}, 0o644); err != nil {
		return err
	}
	if err := putFiles(ctx, machine, hostFiles(), 0o644); err != nil {
		return err
	}
	setup := strings.Join(append(hostSetup(),
		"sudo install -m 755 /tmp/dragrace /usr/local/bin/dragrace-guard",
		"sudo install -d -m 700 -o racer -g racer /var/lib/dragrace-racer /var/lib/dragrace-racer/bin",
		// A first racer binary: from then on it updates itself.
		"(test -e /var/lib/dragrace-racer/bin/dragrace || sudo install -m 755 -o racer -g racer "+
			"/tmp/dragrace /var/lib/dragrace-racer/bin/dragrace)",
		"rm /tmp/dragrace",
		"sudo install -d -m 700 /etc/credstore.encrypted",
	), " && ")
	if _, err := machine.Shell(ctx, setup); err != nil {
		return err
	}
	secrets := map[string]string{"digitalocean-token": strings.TrimSpace(os.Getenv("DIGITALOCEAN_TOKEN")),
		"racer-token": racerToken, "github-token": githubToken}
	for name, secret := range secrets {
		encrypt := "sudo systemd-creds encrypt --name=" + name + " - /etc/credstore.encrypted/" + name
		if err := machine.ShellInput(ctx, encrypt, secret); err != nil {
			return fmt.Errorf("the %s credential: %w", name, err)
		}
	}
	start := strings.Join([]string{
		"sudo systemctl daemon-reload",
		"sudo systemctl enable --now dragrace-guard.service",
		"sudo systemctl enable dragrace-racer.service",
		"sudo systemctl restart dragrace-guard.service dragrace-racer.service",
		"sudo systemctl enable --now dragrace-racer-check.timer",
		"sleep 3",
		"systemctl is-active dragrace-guard.service dragrace-racer.service",
	}, " && ")
	if _, err := machine.Shell(ctx, start); err != nil {
		log.Printf("not running; the logs: ssh cook@%s journalctl -u dragrace-guard -u dragrace-racer", *host)
		return err
	}
	fmt.Printf("the racer is serving: guard cap $%.2f a month, sizes %v\n", *capUSD, guardConfig.Sizes)
	return nil
}
