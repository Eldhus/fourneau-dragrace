# fourneau-dragrace

**At three in the morning, when fourneau, roux or this repository has
changed, HTTP servers race.** Go's net/http, axum on tokio, Roc's
[basic-webserver](https://github.com/roc-lang/basic-webserver), and two built
on [fourneau](https://github.com/Eldhus/fourneau) (a Zig app, and a Roc app on
[roux](https://github.com/Eldhus/roux), the Roc platform cooked on fourneau)
take turns on the same DigitalOcean droplet while a second droplet fires
[oha](https://github.com/hatoo/oha) at them. The results land on a site
served by fourneau itself.

A drag race: a straight line, the same track for everyone, the clock
decides. Part of [Eldhus](https://github.com/Eldhus).

Status: the site is up at https://fourneau.y2kbugger.com/; it keeps the races
in its own database and runs them from its own racer, every night at
03:00 New York time when a repository has a new commit
([docs/self-hosting.md](docs/self-hosting.md), [TODO.md](TODO.md)).
Workloads: plaintext, a 4 KiB echo, a templated page, Datastar SSE,
connection churn, and RealWorld's Conduit on SQLite; live demos are
coming.

## Build

```
go build -C tools -o ../out/dragrace ./cmd/dragrace
out/dragrace toolchain           # Zig, Roc, oha and the musl files, at versions.json's pins
out/dragrace race local          # race on this machine (server and loader on separate CPUs)
out/dragrace site build          # the site, a roux app
(cd site && ROUX_PORT=8090 ../out/bin/dragrace-site)   # http://127.0.0.1:8090/, its races in site/site.db
out/dragrace site dev            # working on the UI: http://127.0.0.1:8090/ rebuilt and reloaded on each save
```

`site build` is LLVM's optimized build (about 90 s), for races and
deploys. `site dev` builds with Roc's dev backend (2 to 3 s from a save
to the reloaded page; a static file, at once) and shows a failed build or
failing expects over the page.

Go from `tools/go.mod`; everything else pinned in `versions.json`
([VERSIONS.md](VERSIONS.md)).

## Working on it

Read first: [RACING.md](RACING.md), [SECURITY.md](SECURITY.md),
[VERSIONS.md](VERSIONS.md), [TODO.md](TODO.md), the last entries of
[DIARY.md](DIARY.md). It builds `../fourneau` and `../roux`, checked out
beside it.

- **The DigitalOcean token** is read from the keyring (seahorse:
  `secret-tool lookup service digitalocean name fourneau-dragrace`) and never written to a
  file, a log or a command line. SECURITY.md has the rest.
- **Every version is pinned** in `versions.json` (VERSIONS.md); nothing
  floats, and an update says why.
- The tool is Go, standard library only; the site is a roux app, the
  demo of what it races.

## Read

| file | what it is |
|---|---|
| [RACING.md](RACING.md) | how a race runs, the layout, every command |
| [CONTRIBUTING.md](CONTRIBUTING.md) | tune a competitor, add one, what fair means |
| [VERSIONS.md](VERSIONS.md) | every pinned version and how to update it |
| [SECURITY.md](SECURITY.md) | tokens, keys, droplets, and first-time setup |
| [docs/self-hosting.md](docs/self-hosting.md) | the site and the racer: machines, a run, the database, the API, the budget |
| [TODO.md](TODO.md) | what is next |
| [DIARY.md](DIARY.md) | what was done, in order |

## License

MIT (`LICENSE`).
