import pf.Path
import pf.Utc
import Checkout
import Hash
import JsonValue
import Run
import Text

## The conduit workload (CONTRIBUTING.md, "The contract"): a slice of
## RealWorld's Conduit API over SQLite. Its database is seeded from one
## model here, the same for every competitor, and the race checks each
## competitor's answers against the same model: what the seed holds is
## known without reading it back.
Conduit :: [].{
	User : { id : U64, username : Str, bio : Str, image : Str, token : Str }
	Article : { id : U64, slug : Str, title : Str, description : Str, body : Str, author : U64, created : Str, tags : List(Str), favorites : List(U64) }
	Comment : { id : U64, article : U64, author : U64, body : Str, created : Str }
	Model : { users : List(User), tags : List(Str), articles : List(Article), comments : List(Comment) }

	## The user whose token every write of the load carries.
	load_user : U64
	load_user = 0

	## The seeded database on the server; each start copies it to `database`.
	seed_name : Str
	seed_name = "conduit-seed.db"

	database_name : Str
	database_name = "conduit.db"

	## A user's token: the first 16 bytes of SHA-256("conduit-token-N"), hex.
	token! : U64 => Try(Str, [Failed(Str), Interrupted])
	token! = |user| {
		sum = Hash.bytes!("conduit-token-${user.to_str()}".to_utf8())?
		Ok(Text.take(sum, 32))
	}

	## The seed, the same every time.
	model! : () => Try(Model, [Failed(Str), Interrupted])
	model! = || {
		tokens = upto(0, users_count).map_try!(Conduit.token!)?
		Ok(Conduit.model_with(tokens))
	}

	## The seed, given each user's token.
	model_with : List(Str) -> Model
	model_with = |tokens| {
		users = upto(0, users_count).map(
			|id| {
				name = "user${pad(id, 3)}"
				{ id, username: name, bio: "Cook number ${id.to_str()}.", image: if id % 2 == 0 "https://example.com/${name}.png" else "", token: tokens.get(id) ?? "" }
			},
		)
		tags = upto(0, tags_count).map(|id| "tag${pad(id, 2)}")
		var $articles = []
		var $comments = []
		var $comment_id = 1
		for id in upto(0, articles_count) {
			body_words = upto(0, 160).map(|i| words.get((id * 7 + i * 13) % words.len()) ?? "")
			tag_names = upto(0, id % 4).map(|k| tags.get((id * 7 + k * 3) % tags_count) ?? "")
			favorites = upto(0, users_count).keep_if(|user| (user * 31 + id) % 17 == 0)
			$articles = $articles.append(
				{
					id,
					slug: "article-${pad(id, 4)}",
					title: "Article ${id.to_str()}",
					description: "What article ${id.to_str()} is about.",
					body: "${Str.join_with(body_words, " ")}.",
					author: id % users_count,
					created: Conduit.time(id * 60_000),
					tags: Text.sorted(tag_names),
					favorites,
				},
			)
			for k in upto(0, id % 4) {
				$comments = $comments.append(
					{
						id: $comment_id,
						article: id,
						author: (id + k + 1) % users_count,
						body: "Comment ${k.to_str()} on article ${id.to_str()}.",
						created: Conduit.time(id * 60_000 + (k + 1) * 3_600_000),
					},
				)
				$comment_id = $comment_id + 1
			}
		}
		{ users, tags, articles: $articles, comments: $comments }
	}

	## The spec's timestamp, ISO 8601 with milliseconds, `offset_ms` after
	## 2026-01-01T00:00:00.000Z.
	time : U64 -> Str
	time = |offset_ms| {
		at = Utc.from_millis_since_epoch((epoch_ms + offset_ms).to_i128())
		millis = (offset_ms % 1000).to_str()
		"${at.to_iso_8601().drop_suffix("Z")}.${Str.repeat("0", 3 - millis.to_utf8().len())}${millis}Z"
	}

	## The model as SQL, in one transaction. Every value is made here of
	## letters, digits and punctuation without quotes.
	seed_sql : Model -> Str
	seed_sql = |model| {
		text = |value| "'${value}'"
		var $lines = ["BEGIN;"]
		for user in model.users {
			image = if user.image == "" "NULL" else text(user.image)
			$lines = $lines.append("INSERT INTO users VALUES (${user.id.to_str()}, ${text(user.username)}, ${text(user.bio)}, ${image}, ${text(user.token)});")
		}
		var $tag_id = 0.U64
		for tag in model.tags {
			$lines = $lines.append("INSERT INTO tags VALUES (${$tag_id.to_str()}, ${text(tag)});")
			$tag_id = $tag_id + 1
		}
		for article in model.articles {
			$lines = $lines.append("INSERT INTO articles VALUES (${article.id.to_str()}, ${text(article.slug)}, ${text(article.title)}, ${text(article.description)}, ${text(article.body)}, ${article.author.to_str()}, ${text(article.created)}, ${text(article.created)});")
			for tag in article.tags {
				$lines = $lines.append("INSERT INTO article_tags SELECT ${article.id.to_str()}, id FROM tags WHERE name = ${text(tag)};")
			}
			for user in article.favorites {
				$lines = $lines.append("INSERT INTO favorites VALUES (${user.to_str()}, ${article.id.to_str()});")
			}
		}
		for comment in model.comments {
			$lines = $lines.append("INSERT INTO comments VALUES (${comment.id.to_str()}, ${comment.article.to_str()}, ${comment.author.to_str()}, ${text(comment.body)}, ${text(comment.created)}, ${text(comment.created)});")
		}
		"${Str.join_with($lines.append("COMMIT;"), "\n")}\n"
	}

	## out/conduit/conduit.db, the seeded database every competitor gets a
	## copy of.
	database : Str -> Str
	database = |root| "${Checkout.out(root)}/conduit/conduit.db"

	## Make out/conduit/conduit.db with the sqlite3 shell: the schema, the
	## seed, WAL mode (kept in the file), VACUUM, then a checkpoint so the
	## copy handed out is one file.
	build_database! : Str => Try({}, [Failed(Str), Interrupted])
	build_database! = |root| {
		path = Conduit.database(root)
		dir = Checkout.parent(path)
		Path.utf8(dir).create_all!() ? |PathErr(err, _)| Failed("${dir}: ${err.to_str()}")
		for name in [path, "${path}-wal", "${path}-shm"] {
			_ = Path.utf8(name).delete!()
		}
		schema = Checkout.read!("${root}/workloads/conduit/schema.sql")?
		model = Conduit.model!()?
		script = "${schema}${Conduit.seed_sql(model)}PRAGMA journal_mode = WAL;\nVACUUM;\n"
		Path.utf8("${dir}/seed.sql").write_utf8!(script) ? |PathErr(err, _)| Failed("${dir}/seed.sql: ${err.to_str()}")
		Run.run!(dir, [], ["sqlite3", "-bail", path, ".read seed.sql"]) ? |err|
			match err {
				Failed(why) => Failed("the conduit database (sqlite3 is needed): ${why}")
				Interrupted => Interrupted
			}
		Run.run!(dir, [], ["sqlite3", path, "PRAGMA wal_checkpoint(TRUNCATE);"])
	}

	# --- the answers the contract asks for ----------------------------------

	## An author as the spec answers: `following` false, `image` null when
	## the user has none.
	author : Model, U64 -> JsonValue
	author = |model, id| {
		user = model.users.get(id) ?? { id, username: "", bio: "", image: "", token: "" }
		Object([
			("username", Text(user.username)),
			("bio", Text(user.bio)),
			("image", if user.image == "" Null else Text(user.image)),
			("following", Boolean(Bool.False)),
		])
	}

	## An article as the spec answers it read without a token (favorited
	## false), with or without its body.
	article : Model, U64, Bool -> JsonValue
	article = |model, id, with_body| {
		a = model.articles.get(id) ?? { id, slug: "", title: "", description: "", body: "", author: 0, created: "", tags: [], favorites: [] }
		members = [
			("slug", Text(a.slug)),
			("title", Text(a.title)),
			("description", Text(a.description)),
			("tagList", Array(a.tags.map(|tag| Text(tag)))),
			("createdAt", Text(a.created)),
			("updatedAt", Text(a.created)),
			("favorited", Boolean(Bool.False)),
			("favoritesCount", Number(a.favorites.len().to_f64())),
			("author", Conduit.author(model, a.author)),
		]
		JsonValue.Object(if with_body members.append(("body", Text(a.body))) else members)
	}

	## GET /api/articles?limit=L&offset=O: newest first.
	list : Model, U64, U64 -> JsonValue
	list = |model, limit, offset| {
		end = if offset + limit < articles_count offset + limit else articles_count
		ids = upto(offset, end).map(|i| articles_count - 1 - i)
		Object([("articles", Array(ids.map(|id| Conduit.article(model, id, Bool.False)))), ("articlesCount", Number(articles_count.to_f64()))])
	}

	## An article the load user has not favorited.
	unfavorited : Model -> U64
	unfavorited = |model|
		match model.articles.find_first(|a| !a.favorites.contains(Conduit.load_user)) {
			Ok(a) => a.id
			Err(_) => crash "the load user favorited every article"
		}

	## With a JSON value's object member set (or replaced).
	with_member : JsonValue, Str, JsonValue -> JsonValue
	with_member = |value, key, member|
		match value {
			Object(members) => Object(members.keep_if(|(name, _)| name != key).append((key, member)))
			other => other
		}
}

users_count : U64
users_count = 100

tags_count : U64
tags_count = 20

articles_count : U64
articles_count = 1000

## 2026-01-01T00:00:00Z.
epoch_ms : U64
epoch_ms = 1_767_225_600_000

words : List(Str)
words = ["stock", "roux", "whisk", "simmer", "fold", "butter", "flour", "reduce", "season", "taste", "plate", "serve", "braise", "sear", "deglaze", "stir", "knead", "proof", "bake", "rest"]

## The numbers from `low` up to but not including `high`.
upto : U64, U64 -> List(U64)
upto = |low, high| List.from_iter((low..<high).iter())

## A number with leading zeros to `width` digits.
pad : U64, U64 -> Str
pad = |n, width| {
	digits = n.to_str()
	length = digits.to_utf8().len()
	if length >= width digits else "${Str.repeat("0", width - length)}${digits}"
}

expect Conduit.time(0) == "2026-01-01T00:00:00.000Z"
expect Conduit.time(61 * 60_000 + 5) == "2026-01-01T01:01:00.005Z"
expect pad(7, 3) == "007"

expect {
	model = Conduit.model_with(List.repeat("t", 100))
	first = model.articles.get(3) ?? crash "no article 3"
	first.slug == "article-0003" and first.tags.len() == 3 and model.comments.len() == 1500 and (model.comments.first() ?? crash "none").id == 1
}

expect {
	model = Conduit.model_with(List.repeat("t", 100))
	sql = Conduit.seed_sql(model)
	sql.starts_with("BEGIN;\nINSERT INTO users VALUES (0, 'user000', 'Cook number 0.', 'https://example.com/user000.png', 't');\nINSERT INTO users VALUES (1, 'user001', 'Cook number 1.', NULL, 't');") and sql.ends_with("COMMIT;\n")
}
