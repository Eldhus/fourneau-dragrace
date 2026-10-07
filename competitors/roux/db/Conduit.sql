-- The conduit workload's queries (RACING.md, "The contract"), typed by
-- roux-db against db/schema.sql, which the build copies from
-- workloads/conduit/schema.sql.

-- The newest articles, without their bodies.
-- name: newest :many(100)
-- @param limit : I64
-- @param offset : I64
-- @column favorites : I64
-- @column tags : Nullable(Str)
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
  u.username, u.bio, u.image,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites,
  (SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at
    JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tags
FROM articles a JOIN users u ON u.id = a.author_id
ORDER BY a.created_at DESC, a.id DESC LIMIT :limit OFFSET :offset;

-- name: count :one
-- @column articles : I64
SELECT count(*) AS articles FROM articles;

-- name: by_slug :one
-- @param slug : Str
-- @column favorites : I64
-- @column tags : Nullable(Str)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
  u.username, u.bio, u.image,
  (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites,
  (SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at
    JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tags
FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = :slug;

-- The request's user, by its token.
-- name: user :one
-- @param token : Str
SELECT id, username, bio, image FROM users WHERE token = :token;

-- Stamped by SQLite's clock, in the spec's form (milliseconds, Z).
-- name: add_comment :one
-- @param author_id : I64
-- @param body : Str
-- @param slug : Str
-- @column created_at : Str
INSERT INTO comments (article_id, author_id, body, created_at, updated_at)
SELECT id, :author_id, :body, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
FROM articles WHERE slug = :slug
RETURNING id, created_at;

-- name: favorite :exec
-- @param user_id : I64
-- @param article_id : I64
INSERT OR IGNORE INTO favorites (user_id, article_id) VALUES (:user_id, :article_id);
