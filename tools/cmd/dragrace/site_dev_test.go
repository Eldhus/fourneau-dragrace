package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestDevChanged(t *testing.T) {
	dev := &devServer{seen: map[string][32]byte{}}
	a, b := [32]byte{1}, [32]byte{2}
	if got := dev.changed(map[string][32]byte{"x.roc": a, "y.css": a}); len(got) != 2 {
		t.Fatalf("first pass: %v", got)
	}
	if got := dev.changed(map[string][32]byte{"x.roc": a, "y.css": a}); len(got) != 0 {
		t.Fatalf("a save that changes nothing: %v", got)
	}
	got := dev.changed(map[string][32]byte{"x.roc": b})
	if strings.Join(got, " ") != "x.roc y.css" {
		t.Fatalf("one changed, one deleted: %v", got)
	}
}

func TestRocDigestIgnoresStatic(t *testing.T) {
	roc := map[string][32]byte{"x.roc": {1}}
	with := map[string][32]byte{"x.roc": {1}, "static/style.css": {9}, "x.rocstache": {3}}
	if rocDigest(roc) != rocDigest(with) {
		t.Fatal("a static file or a template changed the Roc digest")
	}
	if rocDigest(roc) == rocDigest(map[string][32]byte{"x.roc": {2}}) {
		t.Fatal("a Roc change left the digest")
	}
}

func TestDevInput(t *testing.T) {
	for name, want := range map[string]bool{"A.rocstache": true, "A.roc": true, "q.sql": true,
		"site.db": false, ".A.roc.swp": false, "A.roc~": false, "notes.md": false} {
		if devInput(false, name) != want {
			t.Errorf("%s: want %v", name, want)
		}
	}
	if !devInput(true, "style.css") || devInput(true, ".hidden") {
		t.Error("static: every file but a hidden one")
	}
}

func TestDevInject(t *testing.T) {
	page := func(kind, encoding, body string) *http.Response {
		response := &http.Response{Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}
		response.Header.Set("Content-Type", kind)
		if encoding != "" {
			response.Header.Set("Content-Encoding", encoding)
		}
		return response
	}
	response := page("text/html; charset=utf-8", "", "<p>x</p></body></html>")
	if err := devInject(response, 7); err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	if !strings.HasPrefix(string(body), "<p>x</p><script>") || !strings.HasSuffix(string(body), "</script></body></html>") {
		t.Fatalf("not before </body>: %s", body)
	}
	if !strings.Contains(string(body), "const loaded = 7;") || response.ContentLength != int64(len(body)) {
		t.Fatal("generation or length wrong")
	}
	for _, untouched := range []*http.Response{page("text/event-stream", "", "data: x\n\n"),
		page("text/html", "gzip", "zipped")} {
		devInject(untouched, 1)
		body, _ := io.ReadAll(untouched.Body)
		if strings.Contains(string(body), "<script>") {
			t.Fatalf("rewrote %s", untouched.Header)
		}
	}
}
