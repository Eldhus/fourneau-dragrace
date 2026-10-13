package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// The racer host: a small droplet in
// the race region, with no inbound port but the owner's SSH. Users:
//   - cook: the owner's key, sudo;
//   - guard: runs `dragrace-guard guard` (a copy of this binary the owner
//     installs, never updated by a build), the only reader of the
//     DigitalOcean token (an encrypted systemd credential);
//   - racer: runs `dragrace racer serve` from its state directory, a binary
//     it updates itself from the newest build; reaches DigitalOcean only
//     through the guard's socket (group racer).
//
// Its units and the racer's config are files in hosts/racer/ (and
// hosts/common/); the guard's config is made at the install.

// guardBinary is the guard: this dragrace binary, as installed.
const guardBinary = "/usr/local/bin/dragrace-guard"

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

// racerProvision makes the racer droplet, once, with the owner's token.
func racerProvision(ctx context.Context, root string, args []string) error {
	flags := newFlags("racer provision")
	adminKey := flags.String("admin-key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa.pub"),
		"the owner's public key, for the cook user (sudo)")
	size := flags.String("size", "s-1vcpu-512mb-10gb", "droplet size")
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
	fmt.Printf("\nThe racer is up at %s. Next:\n  dragrace racer install -host %s\n",
		host, host)
	return nil
}

// guardConfigFor allows any size up to hourlyMaxUSD an hour, in race.json's
// region and image, under the month's cap, so a class added to race.json
// needs no install; each droplet names the admin key.
func guardConfigFor(race Race, hourlyMaxUSD, capUSD float64, adminKeyID int) GuardConfig {
	return GuardConfig{Region: race.Cloud.Region, Image: race.Cloud.Image, Tag: race.Cloud.Tag,
		HourlyMaxUSD: hourlyMaxUSD, MonthlyCapUSD: capUSD, DropletsMax: 6,
		AgeMaxMinutes: race.Cloud.MaxAgeMinutes, Socket: "/run/dragrace-guard/guard.sock",
		Ledger: "/var/lib/dragrace-guard/ledger.json", AdminKeyID: adminKeyID}
}

// racerInstall sets the racer up, as cook: its files (hosts/racer/,
// hosts/common/), the guard (this binary, pinned) and its config (with the
// admin key's id, looked up on the account), the racer's first binary, and
// the two secrets as encrypted credentials, each sent on SSH's standard
// input: the DigitalOcean token (DIGITALOCEAN_TOKEN, from the keyring) and
// the racer token from the keyring.
func racerInstall(ctx context.Context, root string, args []string) error {
	flags := newFlags("racer install")
	host := flags.String("host", "", "the racer's address")
	key := flags.String("key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa"), "the owner's private key (the cook user)")
	capUSD := flags.Float64("cap", 25, "the most the races may cost in a month, US dollars")
	hourlyMaxUSD := flags.Float64("hourly-max", 0.25, "the most any droplet may cost an hour, US dollars")
	flags.Parse(args)
	if *host == "" {
		return fmt.Errorf("-host is required")
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
	adminKeyID, err := do.adminKeyID(ctx)
	if err != nil {
		return err
	}
	guardConfig := guardConfigFor(race, *hourlyMaxUSD, *capUSD, adminKeyID)
	if err := guardConfig.check(); err != nil {
		return err
	}
	if problems := guardRefusals(race.Cloud, prices, guardConfig); len(problems) > 0 {
		return fmt.Errorf("this guard would refuse race.json: %s", strings.Join(problems, "; "))
	}
	guardJSON, err := json.MarshalIndent(guardConfig, "", "  ")
	if err != nil {
		return err
	}
	racerToken, err := keyringToken(ctx, "racer-token")
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
	if err := installHost(ctx, machine, root, "racer", map[string]string{guardBinary: self},
		map[string]string{"/etc/dragrace-guard/config.json": string(guardJSON)}); err != nil {
		return err
	}
	setup := strings.Join(append(hostSetup("22"),
		"sudo install -m 755 /tmp/dragrace "+guardBinary,
		"sudo install -d -m 700 -o racer -g racer /var/lib/dragrace-racer /var/lib/dragrace-racer/bin",
		// The installer's binary to start from: it replaces itself with the
		// newest release within 10 minutes, idle (racer.update).
		"sudo install -m 755 -o racer -g racer /tmp/dragrace /var/lib/dragrace-racer/bin/dragrace",
		"rm /tmp/dragrace",
		"sudo install -d -m 700 /etc/credstore.encrypted",
	), " && ")
	if _, err := machine.Shell(ctx, setup); err != nil {
		return err
	}
	secrets := map[string]string{"digitalocean-token": strings.TrimSpace(os.Getenv("DIGITALOCEAN_TOKEN")),
		"racer-token": racerToken}
	for name, secret := range secrets {
		encrypt := "sudo systemd-creds encrypt --name=" + name + " - /etc/credstore.encrypted/" + name
		if err := machine.ShellInput(ctx, encrypt, secret); err != nil {
			return fmt.Errorf("the %s credential: %w", name, err)
		}
	}
	// Everything above is safe while a race runs (the running guard and
	// racer keep their binaries and configs until restarted); the restart
	// is not, so it waits for the racer to be idle.
	start := strings.Join([]string{
		racerIdleTest,
		"sudo systemctl daemon-reload",
		"sudo systemctl enable --now dragrace-guard.service",
		"sudo systemctl enable dragrace-racer.service",
		"sudo systemctl restart dragrace-guard.service dragrace-racer.service",
		"sudo systemctl enable --now dragrace-racer-check.timer",
		"sleep 3",
		"systemctl is-active dragrace-guard.service dragrace-racer.service",
	}, " && ")
	if err := whenRacerIdle(ctx, func() error { _, err := machine.Shell(ctx, start); return err },
		sleepContext); err != nil {
		log.Printf("not running; the logs: ssh cook@%s journalctl -u dragrace-guard -u dragrace-racer", *host)
		return err
	}
	fmt.Printf("the racer is serving: guard cap $%.2f a month, any size up to $%.4f an hour\n",
		*capUSD, *hourlyMaxUSD)
	return nil
}

// racerIdleTest fails with racerBusyStatus while the racer races a run (its
// `racing` file: racer.remember). In the same command as the restart, so a
// run can start only in the instant between. A racer restarted before it
// has recorded its run records nothing: the request stays and is taken
// again.
const (
	racerBusyStatus = 75
	racerIdleTest   = "if sudo test -e /var/lib/dragrace-racer/racing; then exit 75; fi"
)

// racerIdleWaits bounds the wait: a minute apart, five hours, past the
// longest race (its droplets' age, race.json's max_age_minutes of 240, and
// the download, launch and teardown around it).
const racerIdleWaits = 300

// whenRacerIdle runs start (which begins with racerIdleTest) until the
// racer is idle and it runs.
func whenRacerIdle(ctx context.Context, start func() error,
	sleep func(context.Context, time.Duration) error) error {
	for wait := 1; wait <= racerIdleWaits; wait++ {
		err := start()
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != racerBusyStatus {
			return err
		}
		if wait == 1 {
			log.Printf("a race is running: the racer restarts when it ends (asking each minute)")
		}
		if err := sleep(ctx, time.Minute); err != nil {
			return err
		}
	}
	return fmt.Errorf("the racer was still racing after %d minutes: install again later", racerIdleWaits)
}
