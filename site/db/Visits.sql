-- The pages' visits, counted (main.roc).

-- name: count :exec
-- @param path : Str
-- @param referrer : Str
-- @param kind : Str
INSERT INTO visits (day, path, referrer, kind, count)
VALUES (strftime('%Y-%m-%d', 'now'), :path, :referrer, :kind, 1)
ON CONFLICT (day, path, referrer, kind) DO UPDATE SET count = count + 1;

-- The last two weeks, newest first (GET /api/visits).
-- name: recent :many(2000)
SELECT day, path, referrer, kind, count FROM visits
WHERE day >= strftime('%Y-%m-%d', 'now', '-14 days')
ORDER BY day DESC, count DESC LIMIT 2000;
