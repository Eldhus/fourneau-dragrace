package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The database built from the seed holds what the model says: the counts,
// and an article with its tags and favorites, read back with the sqlite3
// shell.
func TestConduitDatabaseIsTheModel(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("no sqlite3")
	}
	root := t.TempDir()
	schema, err := os.ReadFile("../../../workloads/conduit/schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(root, "workloads", "conduit"), 0o755)
	os.WriteFile(filepath.Join(root, "workloads", "conduit", "schema.sql"), schema, 0o644)
	if err := buildConduitDatabase(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	model := newConduitModel()
	query := func(sql string) []map[string]any {
		output, err := exec.Command("sqlite3", "-json", conduitDatabase(root), sql).Output()
		if err != nil {
			t.Fatal(err)
		}
		var rows []map[string]any
		json.Unmarshal(output, &rows)
		return rows
	}
	counts := query(`SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM articles) AS articles,
		(SELECT count(*) FROM comments) AS comments, (SELECT count(*) FROM favorites) AS favorites,
		(SELECT journal_mode FROM pragma_journal_mode) AS mode`)[0]
	favorites := 0
	for _, article := range model.articles {
		favorites += len(article.Favorites)
	}
	if counts["users"] != float64(conduitUsers) || counts["articles"] != float64(conduitArticles) ||
		counts["comments"] != float64(len(model.comments)) || counts["favorites"] != float64(favorites) ||
		counts["mode"] != "wal" {
		t.Fatalf("counts %v; model: %d comments, %d favorites", counts, len(model.comments), favorites)
	}
	row := query(`SELECT a.slug, a.title, u.username,
		(SELECT group_concat(name, ',') FROM (SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
		 WHERE at.article_id = a.id ORDER BY t.name)) AS tags,
		(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites
		FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = 'article-0123'`)[0]
	want := model.article(123, false)
	tags := ""
	for i, tag := range want["tagList"].([]any) {
		if i > 0 {
			tags += ","
		}
		tags += tag.(string)
	}
	got := row["tags"]
	if got == nil {
		got = ""
	}
	if row["title"] != want["title"] || got != tags || row["favorites"] != want["favoritesCount"] ||
		row["username"] != want["author"].(map[string]any)["username"] {
		t.Fatalf("article-0123: %v, want %v", row, want)
	}
	newest := model.list(20, 0)["articles"].([]any)[0].(map[string]any)
	if newest["slug"] != "article-0999" {
		t.Fatalf("the newest is %v", newest["slug"])
	}
}
