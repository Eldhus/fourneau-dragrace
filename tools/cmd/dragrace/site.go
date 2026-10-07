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
// roux app, site_build.go). SECURITY.md has the design; in short:
//   - cook: the owner's key, sudo. Root login and passwords are off. (Not
//     "admin": Ubuntu's image has an admin group, so useradd refuses it
//     and cloud-init carries on without the user; 2026-10-06.)
//   - deploy: the nightly's key, forced to rrsync, write-only, into
//     /srv/dragrace/site and nowhere else: the races' data. It cannot run
//     a command, read a file, or touch the site's code.
//   - site: no login; runs the site from /opt/dragrace-site (the binary,
//     its static files, and data, a link to the deploy's), sandboxed by
//     systemd, allowed to bind ports 80 and 443 and nothing more; it
//     obtains its own certificate (fourneau's ACME, through roux's host)
//     into /var/lib/dragrace-site.
// The site reads the data on each request, so a deploy needs no restart;
// the pages, the templates and the static files change only with
// install-server, which is the owner's.

// siteHome is the site's code: root's, read-only to the site.
const siteHome = "/opt/dragrace-site"

// siteUserData makes the users, the firewall and the directories, once.
// The services are install-server's (siteUnits), so a host made earlier
// and one made today run the same ones.
const siteUserData = `#cloud-config
disable_root: true
ssh_pwauth: false
users:
  - name: cook
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys: ["ADMIN_KEY"]
  - name: deploy
    shell: /bin/bash
    ssh_authorized_keys:
      - 'command="/usr/bin/rrsync -wo /srv/dragrace/site",restrict DEPLOY_KEY'
  - name: site
    system: true
    shell: /usr/sbin/nologin
package_update: true
package_upgrade: true
packages: [rsync, ufw, unattended-upgrades]
runcmd:
  - install -d -o deploy -g deploy -m 755 /srv/dragrace/site /srv/dragrace/site/data
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
// left (fourneau's acme.zig).
func siteUnits(host, acmeDirectory string) map[string]string {
	service := `[Unit]
Description=the dragrace site (roux)
After=network-online.target
Wants=network-online.target
ConditionPathExists={site_home}/dragrace-site
[Service]
User=site
StateDirectory=dragrace-site
StateDirectoryMode=0700
WorkingDirectory={site_home}
Environment=ROUX_ADDRESS=0.0.0.0
Environment=ROUX_REDIRECT_PORT=80
Environment=ROUX_ACME_DIRECTORY={acme_directory}
Environment=ROUX_ACME_IDENTIFIER={host}
Environment=ROUX_ACME_STATE=/var/lib/dragrace-site
Environment=ROUX_ACME_PROFILE=shortlived
ExecStart={site_home}/dragrace-site
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
RestartSec=60
[Install]
WantedBy=multi-user.target
`
	// Braced placeholders: a bare ACME_DIRECTORY also matched inside
	// ROUX_ACME_DIRECTORY, and the site would not start (2026-10-06).
	service = strings.NewReplacer("{site_home}", siteHome, "{acme_directory}", acmeDirectory,
		"{host}", host).Replace(service)
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
		// kTLS: the kernel loads tls only for a CAP_NET_ADMIN process;
		// the site has none, so it is loaded at boot.
		"/etc/modules-load.d/fourneau-tls.conf": "tls\n",
	}
}

func commandSite(ctx context.Context, root string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: dragrace site build|provision|install-server|deploy")
	}
	switch args[0] {
	case "build":
		return siteBuildCommand(ctx, root, args[1:])
	case "provision":
		return siteProvision(ctx, root, args[1:])
	case "install-server":
		return siteInstallServer(ctx, root, args[1:])
	case "deploy":
		return siteDeploy(ctx, root, args[1:])
	}
	return fmt.Errorf("unknown: dragrace site %s", args[0])
}

// secretsDir holds keys made here: out/secrets, never committed.
func secretsDir(root string) string { return filepath.Join(outDir(root), "secrets") }

// siteProvision makes the site droplet, once. It makes the deploy key (for
// the GitHub secret), registers the owner's admin key with DigitalOcean (so
// no root password is ever emailed), and waits until SSH answers.
func siteProvision(ctx context.Context, root string, args []string) error {
	flags := newFlags("site provision")
	adminKey := flags.String("admin-key", filepath.Join(os.Getenv("HOME"), ".ssh", "id_rsa.pub"),
		"the owner's public key, for the cook user (sudo)")
	region := flags.String("region", "nyc3", "region")
	size := flags.String("size", "s-1vcpu-512mb-10gb", "droplet size")
	// The image defaults to versions.json's pin, so it is never a second
	// copy of it to keep in step.
	image := flags.String("image", "", "droplet image (default: versions.json's droplet_image)")
	flags.Parse(args)
	if *image == "" {
		versions, err := loadVersions(root)
		if err != nil {
			return err
		}
		*image = versions.DropletImage
	}
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	admin, err := os.ReadFile(*adminKey)
	if err != nil {
		return err
	}
	secrets := secretsDir(root)
	if err := os.MkdirAll(secrets, 0o700); err != nil {
		return err
	}
	deployPrivate := filepath.Join(secrets, "site-deploy-key")
	if _, err := os.Stat(deployPrivate); os.IsNotExist(err) {
		if err := run(ctx, secrets, nil, "ssh-keygen", "-q", "-t", "ed25519", "-N", "",
			"-C", "fourneau-dragrace-deploy", "-f", deployPrivate); err != nil {
			return err
		}
	}
	deployPublic, err := os.ReadFile(deployPrivate + ".pub")
	if err != nil {
		return err
	}
	key, err := do.ensureKey(ctx, "fourneau-dragrace-admin", strings.TrimSpace(string(admin)))
	if err != nil {
		return err
	}
	userData := strings.NewReplacer("ADMIN_KEY", strings.TrimSpace(string(admin)),
		"DEPLOY_KEY", strings.TrimSpace(string(deployPublic))).Replace(siteUserData)
	droplet, err := do.createDroplet(ctx, DropletRequest{
		Name: "fourneau-dragrace-site", Region: *region, Size: *size, Image: *image,
		SSHKeys: []int{key.ID}, Tags: []string{"fourneau-dragrace-site"}, UserData: userData,
		Monitoring: true,
	})
	if err != nil {
		return err
	}
	log.Printf("droplet %d: the site host; waiting for it", droplet.ID)
	droplet, err = waitActive(ctx, do, droplet.ID)
	if err != nil {
		return err
	}
	host := droplet.address("public")
	knownHosts := filepath.Join(secrets, "site-known-hosts")
	machine := SSHMachine{User: "cook", Host: host, Key: privateFor(*adminKey), KnownHosts: knownHosts}
	log.Printf("%s: waiting for SSH, then the first boot (package upgrades: a few minutes)", host)
	if err := waitSSH(ctx, machine); err != nil {
		return err
	}
	fmt.Printf(`
The site host is up at %s; nothing serves until install-server.

Next, as SECURITY.md says:
  1. dragrace site install-server -host %s
  2. GitHub secrets for the nightly (repository settings, environment "dragrace"):
       SITE_HOST         %s
       SITE_DEPLOY_KEY   the contents of %s
       SITE_KNOWN_HOSTS  the contents of %s
`, host, host, host, deployPrivate, knownHosts)
	return nil
}

// privateFor turns ~/.ssh/id_rsa.pub into ~/.ssh/id_rsa.
func privateFor(public string) string { return strings.TrimSuffix(public, ".pub") }

// siteInstallServer builds the site (site_build.go) and installs it on the
// site host as cook: the binary and static files into siteHome, replaced
// whole, and the units. Deliberately not done by the nightly: the deploy
// key can change the data, never code.
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
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	if err := siteBuild(ctx, root, tools); err != nil {
		return err
	}
	machine := SSHMachine{User: "cook", Host: *host, Key: *key,
		KnownHosts: filepath.Join(secretsDir(root), "site-known-hosts")}
	const upload = "/tmp/dragrace-site"
	if _, err := machine.Shell(ctx, "rm -rf "+upload); err != nil {
		return err
	}
	if err := machine.Put(ctx, siteBinary(root), upload+"/dragrace-site"); err != nil {
		return err
	}
	if err := putTree(ctx, machine, filepath.Join(root, "site", "static"), upload+"/static"); err != nil {
		return err
	}
	if err := putUnits(ctx, machine, siteUnits(*host, directory)); err != nil {
		return err
	}
	next := siteHome + ".new"
	script := strings.Join([]string{
		"sudo rm -rf " + next,
		"sudo install -d -m 755 " + next,
		"sudo install -m 755 " + upload + "/dragrace-site " + next + "/dragrace-site",
		"sudo cp -r " + upload + "/static " + next + "/static",
		"sudo chmod -R a+rX " + next,
		"sudo ln -s /srv/dragrace/site/data " + next + "/data",
		"sudo rm -rf " + siteHome,
		"sudo mv " + next + " " + siteHome,
		"rm -rf " + upload,
		"sudo modprobe tls",
		"sudo ufw allow 443/tcp >/dev/null",
		"sudo systemctl daemon-reload",
		"sudo systemctl enable --now dragrace-site-renew.timer",
		"sudo systemctl enable dragrace-site.service",
		"sudo systemctl restart dragrace-site.service",
		"sleep 3",
		"systemctl is-active dragrace-site.service",
	}, " && ")
	if _, err := machine.Shell(ctx, script); err != nil {
		log.Printf("the service did not start; its log: ssh cook@%s journalctl -u dragrace-site", *host)
		return err
	}
	fmt.Printf("the site is serving https://%s/ (Let's Encrypt %s)\n", *host, *acme)
	return nil
}

// putTree copies a small directory's files to the machine, one by one.
func putTree(ctx context.Context, machine SSHMachine, local, remote string) error {
	const filesMax = 256
	count := 0
	return filepath.WalkDir(local, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		count++
		if count > filesMax {
			return fmt.Errorf("%s: more than %d files", local, filesMax)
		}
		relative, err := filepath.Rel(local, path)
		if err != nil {
			return err
		}
		return machine.Put(ctx, path, remote+"/"+filepath.ToSlash(relative))
	})
}

// putUnits copies each file to /tmp and installs it in place as root.
func putUnits(ctx context.Context, machine SSHMachine, units map[string]string) error {
	dir, err := os.MkdirTemp("", "dragrace-units-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	var script []string
	for path, content := range units {
		local := filepath.Join(dir, filepath.Base(path))
		if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
			return err
		}
		remote := "/tmp/" + filepath.Base(path)
		if err := machine.Put(ctx, local, remote); err != nil {
			return err
		}
		script = append(script, fmt.Sprintf("sudo install -m 644 %s %s", remote, path))
	}
	_, err = machine.Shell(ctx, strings.Join(script, " && "))
	return err
}

// siteDeploy sends a data directory to the site host with the deploy key.
// The site reads it on each request: nothing restarts. --delay-updates puts
// every file in place at the end, so a page sees the old race or the new.
func siteDeploy(ctx context.Context, root string, args []string) error {
	flags := newFlags("site deploy")
	host := flags.String("host", os.Getenv("SITE_HOST"), "the site host's address")
	key := flags.String("key", filepath.Join(secretsDir(root), "site-deploy-key"), "the deploy key")
	knownHosts := flags.String("known-hosts", filepath.Join(secretsDir(root), "site-known-hosts"),
		"the site host's key, pinned")
	data := flags.String("data", filepath.Join(root, "site", "data"), "the data directory to publish")
	flags.Parse(args)
	if *host == "" {
		return fmt.Errorf("-host (or SITE_HOST) is required")
	}
	ssh := fmt.Sprintf("ssh -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes "+
		"-o UserKnownHostsFile=%s", quote(*key), quote(*knownHosts))
	if err := run(ctx, root, nil, "rsync", "-rlt", "--delete", "--delay-updates", "-e", ssh,
		*data+"/", "deploy@"+*host+":data/"); err != nil {
		return err
	}
	fmt.Printf("deployed to https://%s/\n", *host)
	return nil
}
