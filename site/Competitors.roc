## The competitors as the Competitors page briefs them:
## the language, then four facts in a fixed order (how the server waits on
## the network, how it renders the menu page, how it talks to SQLite, how
## it is built), the project's own links and the source, and a sentence or
## two for someone meeting it for the first time. Terse: if you know, you
## know; if you don't, look it up. Each fact reads
## "the thing: its details". Each comes from the competitor's README and
## competitor.json; the language must match competitor.json's, which each
## run records.
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
			io: "net/http: goroutine per connection, epoll netpoller",
			templates: "html/template: parsed at startup",
			db: "database/sql: modernc.org/sqlite",
			build: "go build: -trimpath, CGO_ENABLED=0, GOAMD64=v3",
			links: [{ label: "net/http", href: "https://pkg.go.dev/net/http" }, source("go")],
			about: "The baseline, as most teams would ship it: Go on its standard library.",
		},
		{
			name: "axum",
			language: "Rust",
			io: "hyper on tokio: work-stealing threads, epoll",
			templates: "askama: compiled in",
			db: "sqlx",
			build: "cargo build --release: LTO, codegen-units=1, x86-64-v3",
			links: [{ label: "axum", href: "https://github.com/tokio-rs/axum" }, { label: "tokio", href: "https://tokio.rs" }, source("axum")],
			about: "Rust’s most used web framework, by the book: Rust on tokio.",
		},
		{
			name: "fourneau-zig",
			language: "Zig",
			io: "fourneau: io_uring, fiber per connection, shard per core",
			templates: "pure Zig, no engine: the floor",
			db: "SQLite amalgamation: connection per shard",
			build: "zig build: ReleaseSafe, x86-64-v3",
			links: [{ label: "fourneau", href: "https://github.com/Eldhus/fourneau" }, source("fourneau-zig")],
			about: "The server this race exists to measure, bare: Zig on fourneau.",
		},
		{
			name: "roux",
			language: "Roc",
			io: "fourneau: io_uring, fiber per connection, shard per core",
			templates: "rocstache: Roc-typed, compiled to bytecode",
			db: "roux-db: SQL compiled to typed Roc",
			build: "roux build: Roc --opt=speed, host ReleaseSafe, x86-64-v3, one static binary",
			links: [{ label: "roux", href: "https://github.com/Eldhus/roux" }, { label: "fourneau", href: "https://github.com/Eldhus/fourneau" }, source("roux")],
			about: "Eldhus’s Roc platform: Roc on fourneau. The gap to fourneau-zig is what Roc and roux cost.",
		},
		{
			name: "basic-webserver",
			language: "Roc",
			io: "hyper on tokio: epoll, Roc handlers on a thread pool",
			templates: "Html: the platform’s module",
			db: "Sqlite: raw libsqlite3-sys, the host’s pool raised to 32",
			build: "roc build: --opt=speed, the released platform",
			links: [{ label: "basic-webserver", href: "https://github.com/roc-lang/basic-webserver" }, source("basic-webserver")],
			about: "Roc’s reference web platform, as released: Roc on Rust.",
		},
	]

	## A competitor's directory in this repository.
	source : Str -> Link
	source = |name| { label: "source", href: "https://github.com/Eldhus/fourneau-dragrace/tree/master/competitors/${name}" }
}

expect Competitors.all.len() == 5
expect Competitors.all.all(|card| card.links.any(|link| link.label == "source"))
expect Competitors.all.all(|card| card.about != "" and card.io != "" and card.templates != "" and card.db != "" and card.build != "")
