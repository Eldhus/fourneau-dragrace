//! The conduit workload: a slice of RealWorld's Conduit API over SQLite
//! (RACING.md, "The contract"), with sqlx, as an axum team runs SQLite:
//! WAL, synchronous=NORMAL, a pool of readers, and a pool of one writer
//! (SQLite takes one writer at a time; one connection queues them in the
//! pool rather than retrying on SQLITE_BUSY).

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions, SqliteRow,
    SqliteSynchronous,
};
use sqlx::Row;
use std::str::FromStr;
use std::time::Duration;

#[derive(Clone)]
pub struct Conduit {
    readers: SqlitePool,
    writer: SqlitePool,
}

pub async fn open(path: &str) -> Result<Conduit, sqlx::Error> {
    let options = SqliteConnectOptions::from_str(path)?
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(5));
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get()) as u32;
    // The writer first: it makes the WAL's files the readers open.
    let writer = SqlitePoolOptions::new().max_connections(1).connect_with(options.clone()).await?;
    let readers = SqlitePoolOptions::new().max_connections(2 * cores).connect_with(options).await?;
    Ok(Conduit { readers, writer })
}

pub fn routes(conduit: Conduit) -> Router {
    Router::new()
        .route("/api/articles", get(list))
        .route("/api/articles/{slug}", get(article))
        .route("/api/articles/{slug}/comments", post(comment))
        .route("/api/articles/{slug}/favorite", post(favorite))
        .with_state(conduit)
}

#[derive(Serialize)]
struct Profile {
    username: String,
    bio: String,
    image: Option<String>,
    following: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Article {
    slug: String,
    title: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<String>,
    tag_list: Vec<String>,
    created_at: String,
    updated_at: String,
    favorited: bool,
    favorites_count: i64,
    author: Profile,
}

/// What an article's answer needs; the body is added for one article.
const ARTICLE_COLUMNS: &str = "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
    u.username, u.bio, u.image,
    (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites,
    (SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at
        JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)) AS tags";

fn article_from(row: &SqliteRow, with_body: bool) -> (i64, Article) {
    let tags: Option<String> = row.get("tags");
    let article = Article {
        slug: row.get("slug"),
        title: row.get("title"),
        description: row.get("description"),
        body: if with_body { Some(row.get("body")) } else { None },
        tag_list: tags
            .filter(|t| !t.is_empty())
            .map(|t| t.split(',').map(str::to_owned).collect())
            .unwrap_or_default(),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        favorited: false,
        favorites_count: row.get("favorites"),
        author: Profile {
            username: row.get("username"),
            bio: row.get("bio"),
            image: row.get("image"),
            following: false,
        },
    };
    (row.get("id"), article)
}

fn single_article_sql() -> String {
    format!(
        "SELECT {ARTICLE_COLUMNS}, a.body FROM articles a JOIN users u ON u.id = a.author_id
         WHERE a.slug = ?"
    )
}

#[derive(Deserialize)]
struct Page {
    limit: Option<i64>,
    offset: Option<i64>,
}

async fn list(State(conduit): State<Conduit>, Query(page): Query<Page>) -> Response {
    let limit = page.limit.unwrap_or(20).clamp(0, 100);
    let offset = page.offset.unwrap_or(0).max(0);
    let sql = format!(
        "SELECT {ARTICLE_COLUMNS} FROM articles a JOIN users u ON u.id = a.author_id
         ORDER BY a.created_at DESC, a.id DESC LIMIT ? OFFSET ?"
    );
    let rows = match sqlx::query(&sql).bind(limit).bind(offset).fetch_all(&conduit.readers).await {
        Ok(rows) => rows,
        Err(err) => return server_error(err),
    };
    let count: i64 = match sqlx::query_scalar("SELECT count(*) FROM articles")
        .fetch_one(&conduit.readers)
        .await
    {
        Ok(count) => count,
        Err(err) => return server_error(err),
    };
    let articles: Vec<Article> = rows.iter().map(|row| article_from(row, false).1).collect();
    Json(json!({ "articles": articles, "articlesCount": count })).into_response()
}

async fn article(State(conduit): State<Conduit>, Path(slug): Path<String>) -> Response {
    match sqlx::query(&single_article_sql()).bind(&slug).fetch_optional(&conduit.readers).await {
        Ok(Some(row)) => Json(json!({ "article": article_from(&row, true).1 })).into_response(),
        Ok(None) => error(StatusCode::NOT_FOUND, "article not found"),
        Err(err) => server_error(err),
    }
}

/// The request's user, by its token (Authorization: Token ...).
async fn user(conduit: &Conduit, headers: &HeaderMap) -> Option<(i64, Profile)> {
    let token = headers.get("authorization")?.to_str().ok()?.strip_prefix("Token ")?;
    let row = sqlx::query("SELECT id, username, bio, image FROM users WHERE token = ?")
        .bind(token)
        .fetch_optional(&conduit.readers)
        .await
        .ok()??;
    let profile = Profile {
        username: row.get("username"),
        bio: row.get("bio"),
        image: row.get("image"),
        following: false,
    };
    Some((row.get("id"), profile))
}

#[derive(Deserialize)]
struct NewComment {
    comment: CommentBody,
}

#[derive(Deserialize)]
struct CommentBody {
    body: String,
}

async fn comment(
    State(conduit): State<Conduit>,
    Path(slug): Path<String>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let Some((user_id, author)) = user(&conduit, &headers).await else {
        return error(StatusCode::UNAUTHORIZED, "a token is needed");
    };
    let new: NewComment = match serde_json::from_slice(&body) {
        Ok(new) => new,
        Err(_) => return error(StatusCode::UNPROCESSABLE_ENTITY, "a comment needs a body"),
    };
    if new.comment.body.is_empty() {
        return error(StatusCode::UNPROCESSABLE_ENTITY, "a comment needs a body");
    }
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let inserted = sqlx::query_scalar::<_, i64>(
        "INSERT INTO comments (article_id, author_id, body, created_at, updated_at)
         SELECT id, ?, ?, ?, ? FROM articles WHERE slug = ? RETURNING id",
    )
    .bind(user_id)
    .bind(&new.comment.body)
    .bind(&now)
    .bind(&now)
    .bind(&slug)
    .fetch_optional(&conduit.writer)
    .await;
    match inserted {
        Ok(Some(id)) => Json(json!({ "comment": {
            "id": id, "createdAt": now, "updatedAt": now,
            "body": new.comment.body, "author": author,
        } }))
        .into_response(),
        Ok(None) => error(StatusCode::NOT_FOUND, "article not found"),
        Err(err) => server_error(err),
    }
}

async fn favorite(
    State(conduit): State<Conduit>,
    Path(slug): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some((user_id, _)) = user(&conduit, &headers).await else {
        return error(StatusCode::UNAUTHORIZED, "a token is needed");
    };
    let mut tx = match conduit.writer.begin().await {
        Ok(tx) => tx,
        Err(err) => return server_error(err),
    };
    let row = match sqlx::query(&single_article_sql()).bind(&slug).fetch_optional(&mut *tx).await {
        Ok(Some(row)) => row,
        Ok(None) => return error(StatusCode::NOT_FOUND, "article not found"),
        Err(err) => return server_error(err),
    };
    let (article_id, mut article) = article_from(&row, true);
    let added = sqlx::query("INSERT OR IGNORE INTO favorites (user_id, article_id) VALUES (?, ?)")
        .bind(user_id)
        .bind(article_id)
        .execute(&mut *tx)
        .await;
    match added {
        Ok(done) => article.favorites_count += done.rows_affected() as i64,
        Err(err) => return server_error(err),
    }
    if let Err(err) = tx.commit().await {
        return server_error(err);
    }
    article.favorited = true;
    Json(json!({ "article": article })).into_response()
}

/// An error as the spec answers one: {"errors":{"body":[...]}}.
fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "errors": { "body": [message] } }))).into_response()
}

fn server_error(err: sqlx::Error) -> Response {
    eprintln!("conduit: {err}");
    error(StatusCode::INTERNAL_SERVER_ERROR, "server error")
}
