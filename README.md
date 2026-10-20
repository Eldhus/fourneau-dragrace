# fourneau-dragrace

Five HTTP servers race every night that one of them changed: Go's net/http, axum on tokio, Roc's
[basic-webserver](https://github.com/roc-lang/basic-webserver), and two on
[fourneau](https://github.com/Eldhus/fourneau): a Zig app, and a Roc app on
[roux](https://github.com/Eldhus/roux). Each takes its turn on one DigitalOcean droplet while a
second fires [oha](https://github.com/hatoo/oha) at it: plaintext, an echo, a templated page,
server-sent events, connection churn and RealWorld's Conduit on SQLite, over HTTP/1.1 and over TLS
with HTTP/2. The site that keeps the results is a roux app on fourneau, with nothing in front; it
starts the nightly itself.


## Use it

The results: <https://fourneau.y2kbugger.com/>.

To race here, with Go, rustup and a C compiler, beside checkouts of fourneau and roux, and the Roc
nightly roux's `.roc-version` names as `roc`:

```sh
mkdir -p out
roc build tools/main.roc --output=out/dragrace      # the tool, on basic-cli
go build -C tools -o ../out/dragrace-go ./cmd/dragrace  # the commands still in Go
out/dragrace toolchain          # Zig, roc and musl at their pins
out/dragrace race local -quick  # a smoke race; without -quick, hours
```

The tool is moving from Go to Roc. Until it is done, a command the Roc tool does not have yet runs
the Go one built beside it.

The TLS workloads need Linux's kernel TLS: fourneau hands each connection's keys to the kernel
after the handshake, and fourneau-zig and roux do not start over HTTPS without it. Load its module
if `/proc/sys/net/ipv4/tcp_available_ulp` does not list `tls`:

```sh
sudo modprobe tls                                 # now
echo tls | sudo tee /etc/modules-load.d/tls.conf  # and at every boot
```


## The road ahead

- The tool in Roc on basic-cli instead of Go: building and racing here first (done), then the
  racer and its workers, then what the hosts run.
- Static files with compression; idle-connection capacity; SSE with a wait between events.
- A fan-out workload, once roux has pub/sub.
- Each competitor tuned as its community would ([CONTRIBUTING.md](CONTRIBUTING.md)).


## Working on it

```sh
out/dragrace site dev   # the site at http://127.0.0.1:8090/, rebuilt as you save
out/dragrace site build # the optimized build, with the site's tests
```


## Security

Report a problem by a private security advisory on GitHub, not an issue; see
[SECURITY.md](SECURITY.md).


## License

MIT. `site/static/datastar-v1.0.2.js` is Datastar's, by Star Federation (MIT,
`site/static/datastar-LICENSE`).

Part of [Eldhus](https://github.com/Eldhus).
