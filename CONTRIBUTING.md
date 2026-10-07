# Contributing

The point: every competitor is as good as its community can make it, and
the race is fair. Make one faster, fairly, and the next nightly shows it.

## Tune a competitor

1. Clone this repository beside fourneau and roux (RACING.md, Layout).
2. Change `competitors/NAME/`: code, build steps, run arguments.
3. `go build -C tools -o ../out/dragrace ./cmd/dragrace && out/dragrace race local -competitors NAME`
4. Open a pull request: what changed, why it is fair, and before/after
   numbers from your machine.

## Fair

- A server its users would deploy: no benchmark-only modes, no response
  caching across requests, no skipping work the others do.
- The same bytes: the contract in RACING.md, checked before every race.
- Real-world tuning is welcome (worker counts, allocators, socket options,
  release profiles, PGO), with a line in the competitor's README saying what
  and why.
- Every version pinned (VERSIONS.md).

## Add a competitor

A directory under `competitors/` with its source, a `competitor.json` (copy
one: `build` steps run from the repository root unless `cwd` says, `{out}`
is where the binary must land as `{out}/NAME`; `run` gets `{bin}`,
`{address}`, `{port}`), a README, and its name in `race.json`. Its color on
the site is a slot in `site/static/style.css`: colors are validated together for
color blindness and contrast, so say so in the pull request and the
maintainers will pick one.

## The site

A roux app in `site/`: each page a rocstache template (`*.rocstache`;
`Top` and `Bottom` frame them), `View.roc` turning a race into what the
pages show, `Data.roc` reading `site/data/` (`dragrace publish` puts runs
there) on each request. `dragrace site build` compiles the templates,
runs the expects and builds it; run it from `site/` with `ROUX_PORT=8090`.
The `.roc` files beside the templates are generated, not committed.
