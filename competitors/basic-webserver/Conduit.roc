import pf.Sqlite
import http.Header
import http.Response

## The conduit workload (RACING.md, "The contract"): a slice of RealWorld's
## Conduit API over basic-webserver's SQLite: its pool, WAL and
## synchronous=NORMAL, writes in BEGIN IMMEDIATE transactions. Its rows are
## records parsed by column name, and have no nullable fields yet: the SQL
## turns a missing image or tag list into '' and says which. The JSON is
## written here (camelCase names, a null image); each string goes through
## `Json.to_str`, which escapes it.
Conduit :: [].{
	Row : {
		id : I64,
		slug : Str,
		title : Str,
		description : Str,
		body : Str,
		created_at : Str,
		updated_at : Str,
		username : Str,
		bio : Str,
		image : Str,
		has_image : I64,
		favorites : I64,
		tags : Str,
	}

	User : { id : I64, username : Str, bio : Str, image : Str, has_image : I64 }

	limits : Sqlite.QueryLimits
	limits = Sqlite.default_query_limits

	## The article's columns; `:with_body` 0 leaves the body empty (the list).
	article_sql : Str
	article_sql =
		"SELECT a.id, a.slug, a.title, a.description, CASE WHEN :with_body = 1 THEN a.body ELSE '' END AS body, a.created_at, a.updated_at, u.username, u.bio, coalesce(u.image, '') AS image, u.image IS NOT NULL AS has_image, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites, coalesce((SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)), '') AS tags FROM articles a JOIN users u ON u.id = a.author_id"

	## A /api/ request's answer, or `NotFound` for another path.
	respond! : Sqlite.Db, Str, Str, Str, List(Header.Header), List(U8) => Try(Response.Response, [NotFound, DbErr(Str)])
	respond! = |db, method, path, query, headers, body|
		match (method, path.split_on("/")) {
			("GET", ["", "api", "articles"]) => list!(db, query)
			("GET", ["", "api", "articles", slug]) => article!(db, slug)
			("POST", ["", "api", "articles", slug, "comments"]) => comment!(db, slug, headers, body)
			("POST", ["", "api", "articles", slug, "favorite"]) => favorite!(db, slug, headers)
			_ => Err(NotFound)
		}

	list! : Sqlite.Db, Str => Try(Response.Response, [NotFound, DbErr(Str)])
	list! = |db, query| {
		limit = clamp(query_int(query, "limit", 20), 0, 100)
		offset = clamp(query_int(query, "offset", 0), 0, 1_000_000_000)
		rows : List(Row)
		rows = Sqlite.query_many!({ db, query: "${article_sql} ORDER BY a.created_at DESC, a.id DESC LIMIT :limit OFFSET :offset", params: { with_body: 0.I64, limit, offset }, limits }) ? db_err
		count : { articles : I64 }
		count = Sqlite.query!({ db, query: "SELECT count(*) AS articles FROM articles", params: {}, limits }) ? db_err
		items = rows.map(|row| article_json(row, Bool.False, Bool.False))
		Ok(json(200, "{\"articles\":[${Str.join_with(items, ",")}],\"articlesCount\":${count.articles.to_str()}}"))
	}

	article! : Sqlite.Db, Str => Try(Response.Response, [NotFound, DbErr(Str)])
	article! = |db, slug| {
		rows : List(Row)
		rows = Sqlite.query_many!({ db, query: "${article_sql} WHERE a.slug = :slug", params: { with_body: 1.I64, slug }, limits }) ? db_err
		match rows {
			[row] => Ok(json(200, "{\"article\":${article_json(row, Bool.True, Bool.False)}}"))
			_ => Ok(error(404, "article not found"))
		}
	}

	## The request's user, by its token (Authorization: Token ...).
	user! : Sqlite.Db, List(Header.Header) => Try(User, [Unauthorized, DbErr(Str)])
	user! = |db, headers|
		match headers.find_first(|h| h.name.caseless_ascii_equals("authorization")) {
			Ok(header) =>
				match header.value.split_first("Token ") {
					Ok({ before: "", after: token }) => {
						users : List(User)
						users = Sqlite.query_many!({ db, query: "SELECT id, username, bio, coalesce(image, '') AS image, image IS NOT NULL AS has_image FROM users WHERE token = :token", params: { token: token }, limits }) ? db_err
						match users {
							[found] => Ok(found)
							_ => Err(Unauthorized)
						}
					}
					_ => Err(Unauthorized)
				}
			Err(_) => Err(Unauthorized)
		}

	comment! : Sqlite.Db, Str, List(Header.Header), List(U8) => Try(Response.Response, [NotFound, DbErr(Str)])
	comment! = |db, slug, headers, body|
		match user!(db, headers) {
			Err(Unauthorized) => Ok(error(401, "a token is needed"))
			Err(DbErr(why)) => Err(DbErr(why))
			Ok(author) =>
				match comment_text(body) {
					Err(BadComment) => Ok(error(422, "a comment needs a body"))
					Ok(text) => {
						tx = Sqlite.begin!(db, Immediate) ? db_err
						made : List({ id : I64, created_at : Str })
						made = tx.query_many!({ query: "INSERT INTO comments (article_id, author_id, body, created_at, updated_at) SELECT id, :author_id, :text, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now') FROM articles WHERE slug = :slug RETURNING id, created_at", params: { author_id: author.id, text, slug }, limits }) ? db_err
						tx.commit!() ? db_err
						match made {
							[{ id, created_at }] => {
								time = Json.to_str(created_at)
								Ok(json(200, "{\"comment\":{\"id\":${id.to_str()},\"createdAt\":${time},\"updatedAt\":${time},\"body\":${Json.to_str(text)},\"author\":${profile_json(author.username, author.bio, author.image, author.has_image)}}}"))
							}
							_ => Ok(error(404, "article not found"))
						}
					}
				}
		}

	comment_text : List(U8) -> Try(Str, [BadComment])
	comment_text = |bytes|
		match Str.from_utf8(bytes) {
			Ok(text) => {
				parsed : Try({ comment : { body : Str } }, _)
				parsed = Json.parse(text)
				match parsed {
					Ok(found) => if found.comment.body.is_empty() Err(BadComment) else Ok(found.comment.body)
					Err(_) => Err(BadComment)
				}
			}
			Err(_) => Err(BadComment)
		}

	favorite! : Sqlite.Db, Str, List(Header.Header) => Try(Response.Response, [NotFound, DbErr(Str)])
	favorite! = |db, slug, headers|
		match user!(db, headers) {
			Err(Unauthorized) => Ok(error(401, "a token is needed"))
			Err(DbErr(why)) => Err(DbErr(why))
			Ok(user) => {
				tx = Sqlite.begin!(db, Immediate) ? db_err
				tx.execute!({ query: "INSERT OR IGNORE INTO favorites (user_id, article_id) SELECT :user_id, id FROM articles WHERE slug = :slug", params: { user_id: user.id, slug } }) ? db_err
				rows : List(Row)
				rows = tx.query_many!({ query: "${article_sql} WHERE a.slug = :slug", params: { with_body: 1.I64, slug }, limits }) ? db_err
				tx.commit!() ? db_err
				match rows {
					[row] => Ok(json(200, "{\"article\":${article_json(row, Bool.True, Bool.True)}}"))
					_ => Ok(error(404, "article not found"))
				}
			}
		}

	db_err : Sqlite.QueryError -> [DbErr(Str)]
	db_err = |err| DbErr(Str.inspect(err))

	article_json : Row, Bool, Bool -> Str
	article_json = |a, with_body, favorited| {
		tags = if a.tags.is_empty() [] else a.tags.split_on(",").map(|name| Json.to_str(name))
		body = if with_body "\"body\":${Json.to_str(a.body)}," else ""
		"{\"slug\":${Json.to_str(a.slug)},\"title\":${Json.to_str(a.title)},\"description\":${Json.to_str(a.description)},${body}\"tagList\":[${Str.join_with(tags, ",")}],\"createdAt\":${Json.to_str(a.created_at)},\"updatedAt\":${Json.to_str(a.updated_at)},\"favorited\":${if favorited "true" else "false"},\"favoritesCount\":${a.favorites.to_str()},\"author\":${profile_json(a.username, a.bio, a.image, a.has_image)}}"
	}

	profile_json : Str, Str, Str, I64 -> Str
	profile_json = |username, bio, image, has_image| {
		image_json = if has_image == 1 Json.to_str(image) else "null"
		"{\"username\":${Json.to_str(username)},\"bio\":${Json.to_str(bio)},\"image\":${image_json},\"following\":false}"
	}

	json : U16, Str -> Response.Response
	json = |status, text|
		Response.from_status(status)
			.with_headers([{ name: "Content-Type", value: "application/json" }])
			.with_body(Str.to_utf8(text))

	## An error as the spec answers one: {"errors":{"body":[...]}}.
	error : U16, Str -> Response.Response
	error = |status, message| json(status, "{\"errors\":{\"body\":[${Json.to_str(message)}]}}")

	## A query parameter as a number, or the fallback.
	query_int : Str, Str, I64 -> I64
	query_int = |query, name, fallback| {
		found = query.split_on("&").keep_oks(|pair|
			match pair.split_first("=") {
				Ok(kv) => if kv.before == name I64.from_str(kv.after) else Err(NotIt)
				Err(_) => Err(NotIt)
			})
		List.first(found) ?? fallback
	}

	clamp : I64, I64, I64 -> I64
	clamp = |value, low, high| if value < low low else if value > high high else value
}

expect Conduit.query_int("limit=5&offset=40", "offset", 0) == 40
expect Conduit.query_int("", "limit", 20) == 20
expect Conduit.profile_json("jake", "b", "", 0) == "{\"username\":\"jake\",\"bio\":\"b\",\"image\":null,\"following\":false}"
