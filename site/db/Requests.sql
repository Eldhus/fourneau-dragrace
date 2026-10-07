-- What was asked of the racer (docs/self-hosting.md, "A run").

-- name: add :one
-- @param kind : Str
-- @param asked_by : Str
INSERT INTO requests (kind, asked_by) VALUES (:kind, :asked_by)
RETURNING id, asked_at;

-- The requests not taken yet, oldest first: the racer takes the first.
-- name: waiting :many(50)
SELECT id, kind, asked_by, asked_at FROM requests
WHERE taken_at IS NULL ORDER BY id LIMIT 50;

-- name: take :exec
-- @param id : I64
UPDATE requests SET taken_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = :id AND taken_at IS NULL;
