import pf.Server
import pf.Sqlite
import pf.Url
import db/Conduit as Queries

## The conduit workload (RACING.md, "The contract"): a slice of RealWorld's
## Conduit API over roux's SQLite: the statements typed by roux-db
## (db/Conduit.sql), prepared at start; reads on the request's shard,
## writes on the one writer. The JSON is written here: the spec's names
## are camelCase, and an image may be null, which Roc's derived encoder
## does not write; each string goes through `Json.to_str`, which escapes it.
Conduit :: [].{
	## What an article's JSON needs, from either query's row.
	Item : { slug : Str, title : Str, description : Str, created_at : Str, updated_at : Str, username : Str, bio : Str, image : Sqlite.Nullable(Str), favorites : I64, tags : Sqlite.Nullable(Str) }

	item_of_newest : Queries.Newest -> Item
	item_of_newest = |r| { slug: r.slug, title: r.title, description: r.description, created_at: r.created_at, updated_at: r.updated_at, username: r.username, bio: r.bio, image: r.image, favorites: r.favorites, tags: r.tags }

	item_of_one : Queries.BySlug -> Item
	item_of_one = |r| { slug: r.slug, title: r.title, description: r.description, created_at: r.created_at, updated_at: r.updated_at, username: r.username, bio: r.bio, image: r.image, favorites: r.favorites, tags: r.tags }

	## The answer for a /api/ request, or `NotFound` for another path.
	respond! : Server.Request, Sqlite.Db, Str => Try(Server.Response, [NotFound, DbErr(Sqlite.Err)])
	respond! = |request, db, path|
		match (request.method, path.split_on("/")) {
			("GET", ["", "api", "articles"]) => list!(request, db)
			("GET", ["", "api", "articles", slug]) => article!(request, db, slug)
			("POST", ["", "api", "articles", slug, "comments"]) => comment!(request, db, slug)
			("POST", ["", "api", "articles", slug, "favorite"]) => favorite!(request, db, slug)
			_ => Err(NotFound)
		}

	list! : Server.Request, Sqlite.Db => Try(Server.Response, [NotFound, DbErr(Sqlite.Err)])
	list! = |request, db| {
		limit = clamp(query_int(request.target, "limit", 20), 0, 100)
		offset = clamp(query_int(request.target, "offset", 0), 0, 1_000_000_000)
		reads = Sqlite.read(db, request)
		rows = Queries.newest!(reads, { limit, offset })?
		{ articles } = Queries.count!(reads)?
		items = rows.map(|row| article_json(item_of_newest(row), Null, Bool.False))
		Ok(json(200, "{\"articles\":[${Str.join_with(items, ",")}],\"articlesCount\":${articles.to_str()}}"))
	}

	article! : Server.Request, Sqlite.Db, Str => Try(Server.Response, [NotFound, DbErr(Sqlite.Err)])
	article! = |request, db, slug|
		match Queries.by_slug!(Sqlite.read(db, request), { slug: slug }) {
			Ok(row) => Ok(json(200, "{\"article\":${article_json(item_of_one(row), NotNull(row.body), Bool.False)}}"))
			Err(NotFound) => Ok(error(404, "article not found"))
			Err(DbErr(err)) => Err(DbErr(err))
		}

	## The request's user, by its token (Authorization: Token ...).
	user! : Server.Request, Sqlite.Db => Try(Queries.User, [Unauthorized, DbErr(Sqlite.Err)])
	user! = |request, db|
		match Server.header(request, "authorization") {
			Ok(value) =>
				match value.split_first("Token ") {
					Ok({ before: "", after: token }) =>
						match Queries.user!(Sqlite.read(db, request), { token: token }) {
							Ok(found) => Ok(found)
							Err(NotFound) => Err(Unauthorized)
							Err(DbErr(err)) => Err(DbErr(err))
						}
					_ => Err(Unauthorized)
				}
			Err(_) => Err(Unauthorized)
		}

	comment! : Server.Request, Sqlite.Db, Str => Try(Server.Response, [NotFound, DbErr(Sqlite.Err)])
	comment! = |request, db, slug|
		match user!(request, db) {
			Err(Unauthorized) => Ok(error(401, "a token is needed"))
			Err(DbErr(err)) => Err(DbErr(err))
			Ok(author) =>
				match comment_body!(request) {
					Err(BadComment) => Ok(error(422, "a comment needs a body"))
					Ok(body) => {
						tx = Sqlite.write!(db, request)?
						match Queries.add_comment!(tx, { author_id: author.id, body, slug }) {
							Ok({ id, created_at }) => {
								Sqlite.commit!(tx)?
								time = Json.to_str(created_at)
								Ok(json(200, "{\"comment\":{\"id\":${id.to_str()},\"createdAt\":${time},\"updatedAt\":${time},\"body\":${Json.to_str(body)},\"author\":${profile_json(author.username, author.bio, author.image)}}}"))
							}
							Err(NotFound) => Ok(error(404, "article not found"))
							Err(DbErr(err)) => Err(DbErr(err))
						}
					}
				}
		}

	## The comment's text from {"comment":{"body":"..."}}; read before the
	## writer is taken (roux refuses a body read while it is held).
	comment_body! : Server.Request => Try(Str, [BadComment])
	comment_body! = |request| {
		bytes =
			match Server.read_body!(request, 65_536) {
				Ok(read) => read
				Err(_) => return Err(BadComment)
			}
		text =
			match Str.from_utf8(bytes) {
				Ok(decoded) => decoded
				Err(_) => return Err(BadComment)
			}
		parsed : Try({ comment : { body : Str } }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(found) => if found.comment.body.is_empty() Err(BadComment) else Ok(found.comment.body)
			Err(_) => Err(BadComment)
		}
	}

	favorite! : Server.Request, Sqlite.Db, Str => Try(Server.Response, [NotFound, DbErr(Sqlite.Err)])
	favorite! = |request, db, slug|
		match user!(request, db) {
			Err(Unauthorized) => Ok(error(401, "a token is needed"))
			Err(DbErr(err)) => Err(DbErr(err))
			Ok(user) => {
				tx = Sqlite.write!(db, request)?
				match Queries.by_slug!(Sqlite.reading(tx), { slug: slug }) {
					Err(NotFound) => Ok(error(404, "article not found"))
					Err(DbErr(err)) => Err(DbErr(err))
					Ok(found) => {
						Queries.favorite!(tx, { user_id: user.id, article_id: found.id })?
						# Read again inside the transaction: the count with the new favorite.
						after =
							match Queries.by_slug!(Sqlite.reading(tx), { slug: slug }) {
								Ok(row) => row
								Err(NotFound) => return Err(DbErr(Failed("the article went")))
								Err(DbErr(err)) => return Err(DbErr(err))
							}
						Sqlite.commit!(tx)?
						Ok(json(200, "{\"article\":${article_json(item_of_one(after), NotNull(after.body), Bool.True)}}"))
					}
				}
			}
		}

	## An article's JSON; a Null body leaves it out (the list).
	article_json : Item, Sqlite.Nullable(Str), Bool -> Str
	article_json = |a, maybe_body, favorited| {
		tags =
			match a.tags {
				NotNull(names) if !names.is_empty() => names.split_on(",").map(|name| Json.to_str(name))
				_ => []
			}
		body =
			match maybe_body {
				NotNull(text) => "\"body\":${Json.to_str(text)},"
				Null => ""
			}
		"{\"slug\":${Json.to_str(a.slug)},\"title\":${Json.to_str(a.title)},\"description\":${Json.to_str(a.description)},${body}\"tagList\":[${Str.join_with(tags, ",")}],\"createdAt\":${Json.to_str(a.created_at)},\"updatedAt\":${Json.to_str(a.updated_at)},\"favorited\":${if favorited "true" else "false"},\"favoritesCount\":${a.favorites.to_str()},\"author\":${profile_json(a.username, a.bio, a.image)}}"
	}

	profile_json : Str, Str, Sqlite.Nullable(Str) -> Str
	profile_json = |username, bio, image| {
		image_json =
			match image {
				NotNull(url) => Json.to_str(url)
				Null => "null"
			}
		"{\"username\":${Json.to_str(username)},\"bio\":${Json.to_str(bio)},\"image\":${image_json},\"following\":false}"
	}

	json : U16, Str -> Server.Response
	json = |status, text| { status, headers: [{ name: "Content-Type", value: "application/json" }], body: Str.to_utf8(text) }

	## An error as the spec answers one: {"errors":{"body":[...]}}.
	error : U16, Str -> Server.Response
	error = |status, message| json(status, "{\"errors\":{\"body\":[${Json.to_str(message)}]}}")

	query_int : Str, Str, I64 -> I64
	query_int = |target, name, fallback|
		match Url.query_value(target, name) {
			Ok(text) => I64.from_str(text) ?? fallback
			Err(_) => fallback
		}

	clamp : I64, I64, I64 -> I64
	clamp = |value, low, high| if value < low low else if value > high high else value
}

expect Conduit.profile_json("jake", "a \"cook\"", Null) == "{\"username\":\"jake\",\"bio\":\"a \\\"cook\\\"\",\"image\":null,\"following\":false}"
expect Conduit.query_int("/api/articles?limit=5&offset=40", "offset", 0) == 40
expect Conduit.query_int("/api/articles", "limit", 20) == 20
expect Conduit.clamp(500, 0, 100) == 100
