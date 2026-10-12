## The competitors as the Competitors page briefs them:
## the language, then four facts in a fixed order (how the server waits on
## the network, how it renders the menu page, how it talks to SQLite, how
## it is built), the project's own links and the source, and a few
## sentences for someone meeting it for the first time. Each fact comes
## from the competitor's README and competitor.json; the language must
## match competitor.json's, which each run records.
Competitors :: [].{
	Link : { label : Str, href : Str }

	Card : {
		name : Str,
		language : Str,
		io : Str,
		templates : Str,
		db : Str,
		build : Str,
		links : List(Link),
		about : Str,
	}

	all : List(Card)
	all = [
		{
			name: "go",
			language: "Go",
			io: "net/http: a goroutine per connection, on the runtime’s epoll poller",
			templates: "html/template, parsed once at start",
			db: "database/sql with modernc.org/sqlite (SQLite translated to Go)",
			build: "go build -trimpath, CGO_ENABLED=0 (static), GOAMD64=v3",
			links: [{ label: "net/http", href: "https://pkg.go.dev/net/http" }, source("go")],
			about: "The baseline: Go’s standard library and nothing else. Each connection is ordinary blocking code on its own goroutine, and the runtime parks them all on one poller. It is what most teams would ship without thinking twice.",
		},
		{
			name: "axum",
			language: "Rust",
			io: "tokio’s multi-threaded runtime, a worker per core stealing work (epoll); hyper underneath",
			templates: "askama 0.16, compiled into the binary",
			db: "sqlx 0.8, SQLite bundled",
			build: "cargo build --release, LTO, one codegen unit, x86-64-v3",
			links: [{ label: "axum", href: "https://github.com/tokio-rs/axum" }, { label: "tokio", href: "https://tokio.rs" }, source("axum")],
			about: "Rust’s most used web framework, written the way its documentation shows. Every request is a future; tokio’s worker threads take work from each other so no core sits idle.",
		},
		{
			name: "fourneau-zig",
			language: "Zig",
			io: "fourneau: io_uring, a fiber per connection, one shard per core sharing nothing",
			templates: "hand-written Zig, split into parts at compile time (about 80 lines)",
			db: "SQLite compiled in, a connection per shard",
			build: "zig build, ReleaseSafe (assertions on), x86-64-v3",
			links: [{ label: "fourneau", href: "https://github.com/Eldhus/fourneau" }, source("fourneau-zig")],
			about: "fourneau, the server this race was built to measure, with a handler in plain Zig. io_uring hands the kernel whole batches of work instead of asking about each socket. It shares no template code with roux, so its menu page is the ceiling roux’s templates aim for.",
		},
		{
			name: "roux",
			language: "Roc",
			io: "fourneau underneath: io_uring, fibers, a shard per core",
			templates: "rocstache, compiled to bytecode and run by the host as the response is sent",
			db: "roux’s SQLite, every query typed at build time by roux-db",
			build: "roux build: Roc --opt=speed, the host ReleaseSafe, one static binary",
			links: [{ label: "roux", href: "https://github.com/Eldhus/roux" }, { label: "fourneau", href: "https://github.com/Eldhus/fourneau" }, source("roux")],
			about: "A Roc app on roux, the platform built on fourneau. The handler is pure Roc; the server, the templates and the database belong to the platform, all compiled into one static binary. The distance between roux and fourneau-zig is what Roc costs.",
		},
		{
			name: "basic-webserver",
			language: "Roc",
			io: "hyper on tokio; each handler runs on a pool of threads",
			templates: "the platform’s Html module",
			db: "the platform’s Sqlite, a pool of 32 connections",
			build: "roc build (--opt=speed) against the 0.17.0 release",
			links: [{ label: "basic-webserver", href: "https://github.com/roc-lang/basic-webserver" }, source("basic-webserver")],
			about: "Roc’s own web platform as released, with only its limits raised to take the race’s load. The same language as roux on a different host: Rust where roux is Zig. It speaks plain HTTP only, so it sits out the TLS workloads.",
		},
	]

	## A competitor's directory in this repository.
	source : Str -> Link
	source = |name| { label: "source", href: "https://github.com/Eldhus/fourneau-dragrace/tree/master/competitors/${name}" }
}

expect Competitors.all.len() == 5
expect Competitors.all.all(|card| card.links.any(|link| link.label == "source"))
expect Competitors.all.all(|card| card.about != "" and card.io != "" and card.templates != "" and card.db != "" and card.build != "")
