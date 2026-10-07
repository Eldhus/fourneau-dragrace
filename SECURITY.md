# Security, and first-time setup

## Reporting

A security problem in this repository: open a private security advisory on
GitHub, not an issue.

## The pieces

| piece | lives | can do |
|---|---|---|
| DigitalOcean **race token** | your keyring; the `dragrace` GitHub environment | create, read and delete droplets and SSH keys, create tags. Nothing else: no domains, databases, billing, or other products |
| race droplets | DigitalOcean, about an hour a night | nothing: made per race, deleted after; servers listen only on the private network |
| per-race SSH key | the runner, for one race | reach that night's droplets, then deleted |
| **site host** | one $4 droplet, 24/7 | run the site (a roux app, from `/opt/dragrace-site`): HTTPS on 443 with its own Let's Encrypt certificate (kept in `/var/lib/dragrace-site`, renewed by a daily restart), port 80 redirecting |
| your **admin key** | `~/.ssh/id_rsa` | the `cook` user on the site host, with sudo (root login and passwords are off) |
| **deploy key** | `out/secrets/` and the `dragrace` environment | rsync the races' data into `/srv/dragrace/site` only (rrsync, write-only, `restrict`): no shell, no reads, no code |
| `GITHUB_TOKEN` | Actions, per run | push to this repository's `results` branch (the publish job only) |

The site's binary, templates and static files are installed only by you
(`dragrace site install-server`), never by CI: a leaked deploy key can
write false results, not run code. The site parses the data into typed
records and escapes everything it puts in a page. It runs as an
unprivileged user under systemd's sandbox, allowed to bind ports 80 and
443 and nothing more.

Fork pull requests run `ci.yml` only, which has no secrets. The secrets
live in an environment that only `main` can deploy from.

## The DigitalOcean token

DigitalOcean has no API for making tokens, so this is done in the control
panel: **API → Tokens → Generate New Token**.

- Name: `fourneau-dragrace`
- Expiration: 90 days (a reminder is in TODO.md)
- Scopes: **Custom Scopes**, then exactly:
  - `droplet`: create, read, delete
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

Then **delete the full-access token**: control panel, API → Tokens, its
"…" menu → Delete; and its keyring entry (Passwords and Keys, or
`secret-tool clear` with its attributes). Nothing here ever used it.

Known limit: a droplet token cannot be limited to some droplets, so the race
token could delete the site host too. It is rebuilt in minutes from these
steps, and the token lives only in your keyring and the protected
environment.

## First-time setup

1. Push the repositories to GitHub, public (CI clones fourneau and roux
   anonymously).
2. With `DIGITALOCEAN_TOKEN` set: `out/dragrace site provision`. It makes the
   deploy key in `out/secrets/`, the droplet, and prints its address.
3. `out/dragrace site install-server -host ADDRESS -acme staging`, check
   the site, then again with `-acme production`.
4. GitHub, this repository: Settings → Environments → New environment
   `dragrace`; deployment branches: `main` only; secrets:

   ```
   secret-tool lookup service digitalocean name fourneau-dragrace | gh secret set DIGITALOCEAN_TOKEN --env dragrace
   gh secret set SITE_HOST          --env dragrace --body ADDRESS
   gh secret set SITE_DEPLOY_KEY    --env dragrace < out/secrets/site-deploy-key
   gh secret set SITE_KNOWN_HOSTS   --env dragrace < out/secrets/site-known-hosts
   ```

5. First race, by hand: `gh workflow run nightly -f force=true`.

From then on it races at 03:00 New York time when there is a new commit.
