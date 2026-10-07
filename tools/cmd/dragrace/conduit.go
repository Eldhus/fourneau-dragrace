package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The conduit workload (RACING.md, "The contract"): a slice of RealWorld's
// Conduit API over SQLite. Its database is seeded from one model here, the
// same for every competitor, and the race checks each competitor's answers
// against the same model: what the seed holds is known without reading it
// back.

const (
	conduitUsers    = 100
	conduitTags     = 20
	conduitArticles = 1000
	// conduitLoadUser writes during the load (its token in every write).
	conduitLoadUser = 0
)

var conduitEpoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

// conduitTime is the spec's timestamp: ISO 8601 with milliseconds, UTC.
func conduitTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

type conduitUser struct {
	ID       int
	Username string
	Bio      string
	Image    string // "" is NULL
	Token    string
}

type conduitArticle struct {
	ID          int
	Slug        string
	Title       string
	Description string
	Body        string
	Author      int
	Created     string
	Tags        []string // sorted
	Favorites   []int    // user IDs
}

type conduitComment struct {
	ID      int
	Article int
	Author  int
	Body    string
	Created string
}

type conduitModel struct {
	users    []conduitUser
	tags     []string
	articles []conduitArticle
	comments []conduitComment
}

func conduitToken(user int) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("conduit-token-%d", user)))
	return hex.EncodeToString(sum[:16])
}

var conduitWords = strings.Fields(`stock roux whisk simmer fold butter flour reduce
	season taste plate serve braise sear deglaze stir knead proof bake rest`)

// newConduitModel is the seed, the same every time.
func newConduitModel() conduitModel {
	var model conduitModel
	for id := range conduitUsers {
		user := conduitUser{ID: id, Username: fmt.Sprintf("user%03d", id),
			Bio: fmt.Sprintf("Cook number %d.", id), Token: conduitToken(id)}
		if id%2 == 0 {
			user.Image = fmt.Sprintf("https://example.com/user%03d.png", id)
		}
		model.users = append(model.users, user)
	}
	for id := range conduitTags {
		model.tags = append(model.tags, fmt.Sprintf("tag%02d", id))
	}
	commentID := 1
	for id := range conduitArticles {
		var words []string
		for i := range 160 {
			words = append(words, conduitWords[(id*7+i*13)%len(conduitWords)])
		}
		created := conduitTime(conduitEpoch.Add(time.Duration(id) * time.Minute))
		article := conduitArticle{ID: id, Slug: fmt.Sprintf("article-%04d", id),
			Title: fmt.Sprintf("Article %d", id), Description: fmt.Sprintf("What article %d is about.", id),
			Body: strings.Join(words, " ") + ".", Author: id % conduitUsers, Created: created}
		for k := range id % 4 {
			article.Tags = append(article.Tags, model.tags[(id*7+k*3)%conduitTags])
		}
		sort.Strings(article.Tags)
		for user := range conduitUsers {
			if (user*31+id)%17 == 0 {
				article.Favorites = append(article.Favorites, user)
			}
		}
		model.articles = append(model.articles, article)
		for k := range id % 4 {
			model.comments = append(model.comments, conduitComment{ID: commentID, Article: id,
				Author: (id + k + 1) % conduitUsers, Body: fmt.Sprintf("Comment %d on article %d.", k, id),
				Created: conduitTime(conduitEpoch.Add(time.Duration(id)*time.Minute + time.Duration(k+1)*time.Hour))})
			commentID++
		}
	}
	return model
}

// seedSQL is the model as SQL, in one transaction. Every value is made
// here of letters, digits and punctuation without quotes.
func (model conduitModel) seedSQL() string {
	var sql strings.Builder
	sql.WriteString("BEGIN;\n")
	text := func(value string) string {
		if strings.ContainsAny(value, "'\\") {
			panic("a quote in the seed: " + value)
		}
		return "'" + value + "'"
	}
	for _, user := range model.users {
		image := "NULL"
		if user.Image != "" {
			image = text(user.Image)
		}
		fmt.Fprintf(&sql, "INSERT INTO users VALUES (%d, %s, %s, %s, %s);\n", user.ID,
			text(user.Username), text(user.Bio), image, text(user.Token))
	}
	for id, tag := range model.tags {
		fmt.Fprintf(&sql, "INSERT INTO tags VALUES (%d, %s);\n", id, text(tag))
	}
	for _, article := range model.articles {
		fmt.Fprintf(&sql, "INSERT INTO articles VALUES (%d, %s, %s, %s, %s, %d, %s, %s);\n",
			article.ID, text(article.Slug), text(article.Title), text(article.Description),
			text(article.Body), article.Author, text(article.Created), text(article.Created))
		for _, tag := range article.Tags {
			fmt.Fprintf(&sql, "INSERT INTO article_tags SELECT %d, id FROM tags WHERE name = %s;\n",
				article.ID, text(tag))
		}
		for _, user := range article.Favorites {
			fmt.Fprintf(&sql, "INSERT INTO favorites VALUES (%d, %d);\n", user, article.ID)
		}
	}
	for _, comment := range model.comments {
		fmt.Fprintf(&sql, "INSERT INTO comments VALUES (%d, %d, %d, %s, %s, %s);\n", comment.ID,
			comment.Article, comment.Author, text(comment.Body), text(comment.Created),
			text(comment.Created))
	}
	sql.WriteString("COMMIT;\n")
	return sql.String()
}

// conduitDatabase is the seeded database every competitor gets a copy of.
func conduitDatabase(root string) string { return filepath.Join(outDir(root), "conduit", "conduit.db") }

// buildConduitDatabase makes out/conduit/conduit.db with the sqlite3
// shell: the schema, the seed, WAL mode (kept in the file), VACUUM.
func buildConduitDatabase(ctx context.Context, root string) error {
	path := conduitDatabase(root)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, name := range []string{path, path + "-wal", path + "-shm"} {
		os.Remove(name)
	}
	schema, err := os.ReadFile(filepath.Join(root, "workloads", "conduit", "schema.sql"))
	if err != nil {
		return err
	}
	script := string(schema) + newConduitModel().seedSQL() + "PRAGMA journal_mode = WAL;\nVACUUM;\n"
	scriptPath := filepath.Join(dir, "seed.sql")
	if err := os.WriteFile(scriptPath, []byte(script), 0o644); err != nil {
		return err
	}
	if err := run(ctx, dir, nil, "sqlite3", "-bail", path, ".read seed.sql"); err != nil {
		return fmt.Errorf("the conduit database (sqlite3 is needed): %w", err)
	}
	// A checkpoint folds the WAL into the file: the copy handed out is one file.
	return run(ctx, dir, nil, "sqlite3", path, "PRAGMA wal_checkpoint(TRUNCATE);")
}

// --- the answers the contract asks for --------------------------------------

func (model conduitModel) author(user int) map[string]any {
	u := model.users[user]
	var image any
	if u.Image != "" {
		image = u.Image
	}
	return map[string]any{"username": u.Username, "bio": u.Bio, "image": image, "following": false}
}

// article is an article as the spec answers it, read without a token
// (favorited is false), with or without its body.
func (model conduitModel) article(id int, withBody bool) map[string]any {
	a := model.articles[id]
	tags := []any{}
	for _, tag := range a.Tags {
		tags = append(tags, tag)
	}
	answer := map[string]any{"slug": a.Slug, "title": a.Title, "description": a.Description,
		"tagList": tags, "createdAt": a.Created, "updatedAt": a.Created, "favorited": false,
		"favoritesCount": float64(len(a.Favorites)), "author": model.author(a.Author)}
	if withBody {
		answer["body"] = a.Body
	}
	return answer
}

// list is GET /api/articles?limit=L&offset=O: newest first.
func (model conduitModel) list(limit, offset int) map[string]any {
	articles := []any{}
	for i := offset; i < offset+limit && i < conduitArticles; i++ {
		articles = append(articles, model.article(conduitArticles-1-i, false))
	}
	return map[string]any{"articles": articles, "articlesCount": float64(conduitArticles)}
}

// unfavorited is an article the load user has not favorited.
func (model conduitModel) unfavorited() int {
	for _, article := range model.articles {
		mine := false
		for _, user := range article.Favorites {
			mine = mine || user == conduitLoadUser
		}
		if !mine {
			return article.ID
		}
	}
	panic("the load user favorited everything")
}
