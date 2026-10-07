# Security, and first-time setup

What each secret opens, where it lives, and how the hosts are set up. The
design behind it, and why the token lives where it does:
[docs/self-hosting.md](docs/self-hosting.md).

## Reporting

A security problem in this repository: open a private security advisory on
GitHub, not an issue.

## The pieces

| piece | lives | taken, it can |
|---|---|---|
| DigitalOcean **race token** | your keyring; the racer, as the guard's encrypted credential | the account's droplets and keys (rotate it); through the racer, only what the guard allows |
| the **guard** | the racer: `/usr/local/bin/dragrace-guard`, its own user, installed by you only | spend up to the monthly cap, on the sizes in its config (`/etc/dragrace-guard/config.json`, yours) |
| **GitHub token** (fine-grained) | your keyring; the racer | dispatch and cancel this repository's builds (Actions read and write; nothing else) |
| **racer token** | your keyring; the racer; the site host (`secrets/racer-token`) | ask checks, post runs and results, ask for backups |
| **manual token** | your keyring; the site host | ask for races (the budget still holds) |
| a run's **worker token** | that run's loaders; the site's database | post that run's results while it races |
| a run's **SSH key** | the racer; that run's loaders | that run's droplets, while they live |
| your **admin key** | `~/.ssh/id_rsa` | the `cook` user (sudo) on the site host and the racer; root login and passwords are off |
| GitHub's `build.yml` | Actions, its own token | make releases of builds; no secret of ours |

The site host holds no DigitalOcean or GitHub token: a site taken over can
write false results and read the races, nothing more. It runs as an
unprivileged user under systemd's sandbox, allowed to bind ports 80 and
443. The racer has no port open but SSH; the racer user reaches
DigitalOcean only through the guard's socket, and cannot read the token.
A build, which GitHub makes, runs on the racer (it updates itself) and on
the site host: GitHub's account is in the trust, as it was when the
nightly ran there.

Fork pull requests run `ci.yml` only, which has no secrets.

## The DigitalOcean token

DigitalOcean has no API for making tokens, so this is done in the control
panel: **API → Tokens → Generate New Token**.

- Name: `fourneau-dragrace`
- Expiration: 90 days (a reminder is in TODO.md)
- Scopes: **Custom Scopes**, then exactly:
  - `droplet`: create, read, delete (and `update`, once, for `site backups`)
  - `ssh_key`: create, read, delete
  - `tag`: create, read

  The panel adds the read scopes these require on its own. If a race fails
  with 403 on create, add `regions:read`, `sizes:read`, `image:read` and
  `vpc:read`, and nothing more.

Keep it in your keyring, never in a file:

```
secret-tool store --label fourneau-dragrace-digitalocean service digitalocean name fourneau-dragrace
export DIGITALOCEAN_TOKEN=$(secret-tool lookup service digitalocean name fourneau-dragrace)
```

Known limit: a droplet token cannot be limited to some droplets, so the
token could delete the site host too. That is why it sits behind the
guard on the racer, and the site host keeps the nightly copies and
DigitalOcean's backups.

## The GitHub token

GitHub has no API for making tokens: GitHub → Settings → Developer
settings → Fine-grained tokens → Generate new token
(https://github.com/settings/personal-access-tokens/new), exactly:

- Token name: `fourneau-dragrace-racer`
- Description: `The racer droplet dispatches build.yml for new fourneau or
  roux commits. Actions read/write on fourneau-dragrace only. Lives in the
  keyring and the racer's encrypted credential.`
- Resource owner: `Eldhus`
- Expiration: 1 year (a reminder is in TODO.md)
- Repository access: Only select repositories → `Eldhus/fourneau-dragrace`
- Permissions → Repository permissions: **Actions: Read and write**.
  GitHub adds **Metadata: Read-only** itself. Nothing else.

Into the keyring (it asks for the value: never on a command line):

```
secret-tool store --label fourneau-dragrace-github-token service fourneau-dragrace name github-token
```

To cross-check later: the token's page lists exactly these, and the
racer's log shows `dispatching build.yml` when it used it.

## First-time setup

With `DIGITALOCEAN_TOKEN` exported from the keyring, from this checkout
(`go build -C tools -o ../out/dragrace ./cmd/dragrace`):

1. The site host, once: `out/dragrace site provision` (it prints the
   address), then `out/dragrace site install-server -host ADDRESS` (it
   makes the racer and manual tokens in your keyring if missing) and
   `out/dragrace site backups` (DigitalOcean's weekly copies, 20% of the
   droplet).
2. The racer, once: `out/dragrace racer provision`, then
   `out/dragrace racer install -host RACER -site ADDRESS [-cap 25]`.
3. Push to main: `build.yml` builds and releases; the site host deploys it
   within a minute; the racer updates itself.
4. A first race by hand: `out/dragrace site race-now -host ADDRESS`.

From then on the racer asks for a check at 03:00 New York time, and races
when a repository has a new commit. `install-server` and `racer install`
are run again only to change a unit, a config, a token or the pinned
guard and host agent.

## Rotating a token

- DigitalOcean: make the new one, store it in the keyring, run `racer
  install` again (it re-encrypts the credential), delete the old one.
- Racer or manual: `secret-tool clear service fourneau-dragrace name
  racer-token`, then `site install-server` and `racer install` (a new one
  is made and sent to both).

## Migrations and copies

roux opens only a database that holds exactly the schema the site was
built with (no migrations yet), so a schema change does not deploy itself:
the new site does not answer, the host agent puts the old one back and
marks that build failed. Then, as cook on the site host:

```
sudo systemctl stop dragrace-host-agent.timer dragrace-site
sudo -u site sqlite3 /var/lib/dragrace-site/site.db < migration.sql
sudo rm /opt/dragrace-site/failed/*            # let the agent try the build again
sudo systemctl start dragrace-host-agent.timer  # it deploys within a minute
```

The site's copies are in `/var/lib/dragrace-site/backups/` (one after each
night's check, thirty kept); a copy is a whole SQLite database, opened as
is. To restore one, stop the site, copy it over `site.db` (removing
`site.db-wal` and `site.db-shm`), start it.
