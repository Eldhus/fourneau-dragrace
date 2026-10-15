# Contributing

Every competitor should be as good as its community can make it, and the race fair. Make one
faster, fairly, and the next nightly shows it.

**The field is closed**: go, axum, fourneau-zig, roux and basic-webserver race, and no
one else.


## Tune a competitor

1. Clone this repository beside fourneau and roux (README, Use it).
2. Change `competitors/NAME/`: its code, its build.
3. `go build -C tools -o ../out/dragrace ./cmd/dragrace && out/dragrace race local -competitors NAME`
4. Open a pull request: what changed, why it is fair, and before/after numbers from your machine.


## Fair

- A server its users would deploy.
    - No benchmark-only modes, no response caching across requests, no skipping work the others do.
- The same bytes: the contract below, checked before every race.
- Real-world tuning is welcome: worker counts, allocators, socket options, release profiles, PGO.
    - With a line in the competitor's README saying what and why.
- Every version pinned, in its tool's own file.


## The contract

A competitor is a directory under `competitors/` with its source, a README, its name in
`race.json`, and a `competitor.json`:

```json
"build": {
  "argv": ["cargo", "build", "--release", "--locked"],
  "binary": "target/release/dragrace-axum"
},
"tls": true
```

- **Built** by that one command in its directory, for x86-64-v3 with AES and PCLMUL.
    - A command starting `zig`, `roc` or `roux` gets the pinned one.
    - Whatever else the build reads is listed in `inputs`.
- **Started** with no arguments and `ROUX_ADDRESS`, `ROUX_PORT` (8080) and `ROUX_DATABASE` set.
    - With `"tls": true`, also `ROUX_TLS_CERT` and `ROUX_TLS_KEY` (PEM).
    - TLS is 1.3, X25519, AES-128-GCM, no session resumption, HTTP/2 by ALPN.
- **Answers**:
    - `GET /plaintext`: `Hello, World!` as `text/plain; charset=utf-8`
    - `POST /echo`: the body back, up to 64 KiB, as `application/octet-stream`
    - `GET /menu`: `workloads/menu.html`, rendered from a template per request, every value escaped
    - `GET /sse?datastar={"count":N}`: `workloads/sse.txt` for N + 1 as `text/event-stream`
        - An event a chunk; 400 without signals.
    - Conduit, a slice of [RealWorld](https://realworld-docs.netlify.app/):
        - On the SQLite at `ROUX_DATABASE`; its schema is `workloads/conduit/schema.sql`, WAL, `synchronous=NORMAL`.
        - `GET /api/articles`, `GET /api/articles/SLUG`
        - `POST /api/articles/SLUG/comments`, `POST /api/articles/SLUG/favorite`
        - The writes need `Authorization: Token TOKEN`.
    - Anything else: 404.

The race checks the answers before racing; one that differs does not finish in that mode.
