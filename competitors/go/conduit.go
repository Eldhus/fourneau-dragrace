package main

// The conduit workload: a slice of RealWorld's Conduit API over SQLite
// (RACING.md, "The contract"), with database/sql and modernc.org/sqlite
// (SQLite in pure Go: the binary stays static). As a Go team runs SQLite:
// WAL, synchronous=NORMAL, a pool of readers, one writer (SQLite takes one
// at a time; a single connection queues them in Go instead of retrying on
// SQLITE_BUSY), and BEGIN IMMEDIATE for writes.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type conduit struct {
	readers *sql.DB
	writer  *sql.DB
}

func openConduit(path string) (*conduit, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)" +
		"&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
	readers, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	readers.SetMaxOpenConns(2 * runtime.GOMAXPROCS(0))
	readers.SetMaxIdleConns(2 * runtime.GOMAXPROCS(0))
	writer, err := sql.Open("sqlite", dsn+"&_txlock=immediate")
	if err != nil {
		return nil, err
	}
	writer.SetMaxOpenConns(1)
	if err := writer.Ping(); err != nil {
		return nil, err
	}
	return &conduit{readers: readers, writer: writer}, nil
}

func (c *conduit) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/articles", c.list)
	mux.HandleFunc("GET /api/articles/{slug}", c.article)
	mux.HandleFunc("POST /api/articles/{slug}/comments", c.comment)
	mux.HandleFunc("POST /api/articles/{slug}/favorite", c.favorite)
}

type profile struct {
	Username  string  `json:"username"`
	Bio       string  `json:"bio"`
	Image     *string `json:"image"`
	Following bool    `json:"following"`
}

type article struct {
	Slug           string   `json:"slug"`
	Title          string   `json:"title"`
	Description    string   `json:"description"`
	Body           *string  `json:"body,omitempty"`
	TagList        []string `json:"tagList"`
	CreatedAt      string   `json:"createdAt"`
	UpdatedAt      string   `json:"updatedAt"`
	Favorited      bool     `json:"favorited"`
	FavoritesCount int      `json:"favoritesCount"`
	Author         profile  `json:"author"`
}

// articleColumns are what an article's answer needs, a row each; the body
// is selected only for a single article.
const articleColumns = `a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
	u.username, u.bio, u.image,
	(SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
	(SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at
		JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name))`

type scanner interface{ Scan(...any) error }

func scanArticle(row scanner, body *string) (int64, article, error) {
	var a article
	var id int64
	var tags sql.NullString
	targets := []any{&id, &a.Slug, &a.Title, &a.Description, &a.CreatedAt, &a.UpdatedAt,
		&a.Author.Username, &a.Author.Bio, &a.Author.Image, &a.FavoritesCount, &tags}
	if body != nil {
		targets = append(targets, body)
		a.Body = body
	}
	if err := row.Scan(targets...); err != nil {
		return 0, a, err
	}
	a.TagList = []string{}
	if tags.Valid && tags.String != "" {
		a.TagList = strings.Split(tags.String, ",")
	}
	return id, a, nil
}

func (c *conduit) list(w http.ResponseWriter, r *http.Request) {
	limit := queryInt(r, "limit", 20, 100)
	offset := queryInt(r, "offset", 0, 1<<30)
	rows, err := c.readers.QueryContext(r.Context(), `SELECT `+articleColumns+`
		FROM articles a JOIN users u ON u.id = a.author_id
		ORDER BY a.created_at DESC, a.id DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		serverError(w, err)
		return
	}
	defer rows.Close()
	articles := []article{}
	for rows.Next() {
		_, a, err := scanArticle(rows, nil)
		if err != nil {
			serverError(w, err)
			return
		}
		articles = append(articles, a)
	}
	if err := rows.Err(); err != nil {
		serverError(w, err)
		return
	}
	var count int
	if err := c.readers.QueryRowContext(r.Context(), "SELECT count(*) FROM articles").Scan(&count); err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"articles": articles, "articlesCount": count})
}

func (c *conduit) article(w http.ResponseWriter, r *http.Request) {
	var body string
	_, a, err := scanArticle(c.readers.QueryRowContext(r.Context(), `SELECT `+articleColumns+
		`, a.body FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = ?`,
		r.PathValue("slug")), &body)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"article": a})
}

// user is the request's user by its token (Authorization: Token ...).
func (c *conduit) user(r *http.Request) (int64, profile, bool) {
	token, found := strings.CutPrefix(r.Header.Get("Authorization"), "Token ")
	var id int64
	var p profile
	if !found || token == "" {
		return 0, p, false
	}
	err := c.readers.QueryRowContext(r.Context(),
		"SELECT id, username, bio, image FROM users WHERE token = ?", token).
		Scan(&id, &p.Username, &p.Bio, &p.Image)
	return id, p, err == nil
}

func (c *conduit) comment(w http.ResponseWriter, r *http.Request) {
	userID, author, ok := c.user(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "a token is needed")
		return
	}
	var request struct {
		Comment struct {
			Body string `json:"body"`
		} `json:"comment"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&request); err != nil ||
		request.Comment.Body == "" {
		writeError(w, http.StatusUnprocessableEntity, "a comment needs a body")
		return
	}
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	var id int64
	err := c.writer.QueryRowContext(r.Context(), `INSERT INTO comments
		(article_id, author_id, body, created_at, updated_at)
		SELECT id, ?, ?, ?, ? FROM articles WHERE slug = ? RETURNING id`,
		userID, request.Comment.Body, now, now, r.PathValue("slug")).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comment": map[string]any{"id": id,
		"createdAt": now, "updatedAt": now, "body": request.Comment.Body, "author": author}})
}

func (c *conduit) favorite(w http.ResponseWriter, r *http.Request) {
	userID, _, ok := c.user(r)
	if !ok {
		writeError(w, http.StatusUnauthorized, "a token is needed")
		return
	}
	tx, err := c.writer.BeginTx(r.Context(), nil)
	if err != nil {
		serverError(w, err)
		return
	}
	defer tx.Rollback()
	var body string
	articleID, a, err := scanArticle(tx.QueryRowContext(r.Context(), `SELECT `+articleColumns+
		`, a.body FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = ?`,
		r.PathValue("slug")), &body)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "article not found")
		return
	}
	if err != nil {
		serverError(w, err)
		return
	}
	added, err := tx.ExecContext(r.Context(),
		"INSERT OR IGNORE INTO favorites (user_id, article_id) VALUES (?, ?)", userID, articleID)
	if err != nil {
		serverError(w, err)
		return
	}
	if n, _ := added.RowsAffected(); n > 0 {
		a.FavoritesCount++
	}
	if err := tx.Commit(); err != nil {
		serverError(w, err)
		return
	}
	a.Favorited = true
	writeJSON(w, http.StatusOK, map[string]any{"article": a})
}

func queryInt(r *http.Request, name string, fallback, most int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(name))
	if err != nil || value < 0 {
		return fallback
	}
	return min(value, most)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

// writeError answers as the spec's errors: {"errors":{"body":[...]}}.
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"errors": map[string][]string{"body": {message}}})
}

func serverError(w http.ResponseWriter, err error) {
	log.Print(err)
	writeError(w, http.StatusInternalServerError, "server error")
}
