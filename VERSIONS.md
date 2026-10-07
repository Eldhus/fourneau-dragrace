# Versions

Everything a race depends on is pinned, so a result can be reproduced and a
change in it has a cause. The exceptions are fourneau and roux: the nightly
races the newest commit on each one's main branch, on purpose, and records
which.

| what | pinned to | where | to update |
|---|---|---|---|
| Zig | 0.17.0 | `versions.json` (url, sha256) | new url; `sha256sum` the tarball; run `dragrace toolchain` |
| Roc | nightly-2026-10-04-130536d | `versions.json` (url, sha256) | new nightly url and sha256; update `roc_musl.commit` to the nightly's commit and the two files' sha256 |
| musl crt1.o, libc.a | Roc's test platform at that commit | `versions.json` (`roc_musl`) | from the new commit's `test/fx/platform/targets/x64musl/`, sha256 of each file |
| oha | 1.16.0 | `versions.json` (url, sha256) | the release's `oha-linux-amd64` and its sha256 |
| Go | 1.27.1 | `toolchain` line in `competitors/go/go.mod` and `tools/go.mod` | `go mod edit -toolchain=goX.Y.Z` in both; `versions.json` note |
| Rust | 1.94.1 | `competitors/axum/rust-toolchain.toml` | edit `channel`; `versions.json` note |
| axum, tokio | 0.8.9, 1.53.2 | `competitors/axum/Cargo.lock` | `cargo update -p axum` (or tokio); commit the lock |
| basic-webserver | 0.17.0 | the platform URL in `competitors/basic-webserver/main.roc` (the file name is the bundle's hash) | a release that targets the pinned Roc nightly: its `.tar.zst` URL from the release page; the `roc:` line in the app header to match |
| Datastar (the site's tabs) | 1.0.2 | `site/static/datastar-v1.0.2.js`, sha256 2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a | from roc-lang/basic-webserver's `examples/datastar/` at 0.17.0 (`git show 0.17.0:examples/datastar/datastar-v1.0.2.js`); a new release: its bundle from the Datastar release, sha256 noted here, the `<script>` in `site/Top.rocstache` renamed |
| droplet image | ubuntu-26-04-x64 | `race.json` (`cloud.image`), `versions.json` (a test holds them equal; `site provision` reads it) | a new LTS slug; the runner image too (axum links glibc) |
| runner | ubuntu-26.04 | `.github/workflows/*.yml` | must match the droplet image's glibc |
| GitHub actions | commit SHAs | `.github/workflows/*.yml` | the new release's commit SHA, tag in the comment |
| fourneau | main, recorded per race | `versions.json` (`fourneau`) | nothing: it moves |
| roux | main, recorded per race | `versions.json` (`roux`) | nothing: it moves |

Any pin change is a commit, so the nightly races it the night after.
