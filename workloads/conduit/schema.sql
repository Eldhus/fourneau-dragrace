-- The conduit workload's database (RACING.md, "The contract"): a slice of
-- RealWorld's Conduit (realworld-docs.netlify.app). Every competitor is
-- handed a fresh copy, seeded the same (dragrace build: conduit.go), and
-- opens it in WAL mode with synchronous=NORMAL. STRICT, as roux requires;
-- competitors/roux/db/schema.sql is this file, byte for byte.

CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  bio TEXT NOT NULL,
  image TEXT,
  -- A session: `Authorization: Token <token>` (the spec's JWT, as a row).
  token TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE articles (
  id INTEGER PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  body TEXT NOT NULL,
  author_id INTEGER NOT NULL REFERENCES users (id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

CREATE INDEX articles_by_created ON articles (created_at, id);

CREATE TABLE tags (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
) STRICT;

CREATE TABLE article_tags (
  article_id INTEGER NOT NULL REFERENCES articles (id),
  tag_id INTEGER NOT NULL REFERENCES tags (id),
  PRIMARY KEY (article_id, tag_id)
) STRICT, WITHOUT ROWID;

CREATE TABLE favorites (
  user_id INTEGER NOT NULL REFERENCES users (id),
  article_id INTEGER NOT NULL REFERENCES articles (id),
  PRIMARY KEY (user_id, article_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX favorites_by_article ON favorites (article_id);

CREATE TABLE comments (
  id INTEGER PRIMARY KEY,
  article_id INTEGER NOT NULL REFERENCES articles (id),
  author_id INTEGER NOT NULL REFERENCES users (id),
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

CREATE INDEX comments_by_article ON comments (article_id);
