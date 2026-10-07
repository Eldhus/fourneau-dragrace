-- Each repository's newest commit, as the racer last saw it.

-- name: set :exec
-- @param repository : Str
-- @param commit_sha : Str
INSERT INTO heads (repository, commit_sha) VALUES (:repository, :commit_sha)
ON CONFLICT (repository) DO UPDATE SET commit_sha = excluded.commit_sha,
  seen_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');

-- name: all :many(3)
SELECT repository, commit_sha, seen_at FROM heads ORDER BY repository;
