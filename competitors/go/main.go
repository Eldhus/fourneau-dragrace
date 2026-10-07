// The Go competitor: net/http from the standard library, written the way a
// Go team would ship it. See README.md for what you may tune.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

// The templates workload: html/template, parsed once, executed per request
// (it escapes every value for its context).
var menu = template.Must(template.New("menu").Parse(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Menu</title></head>
<body>
<h1>Menu</h1>
<table>
<tr><th>Dish</th><th>Price</th></tr>
{{range .}}<tr><td>{{.Name}}</td><td>{{.Price}}</td></tr>
{{end}}</table>
</body>
</html>
`))

type Dish struct {
	Name  string
	Price int
}

var dishes = []Dish{
	{"Roux", 120}, {"Fish & chips", 290}, {"Crème brûlée", 180},
	{"<b>Bold</b> stew", 240}, {"Skyr & berries", 150}, {"Hákarl", 990},
	{"Plokkfiskur", 310}, {"Kjötsúpa", 270}, {"Rúgbrauð <warm>", 90},
	{"Pylsa með öllu", 120}, {"Flatkaka & hangikjöt", 210}, {"1 < 2 > 0 pie", 160},
}

func main() {
	address := flag.String("address", "127.0.0.1", "address to listen on")
	port := flag.String("port", "8080", "port to listen on")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "Hello, World!")
	})
	mux.HandleFunc("POST /echo", echo)
	mux.HandleFunc("GET /menu", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := menu.Execute(w, dishes); err != nil {
			log.Print(err)
		}
	})
	mux.HandleFunc("GET /sse", datastar)
	server := &http.Server{
		Addr:              net.JoinHostPort(*address, *port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	log.Printf("go on http://%s", server.Addr)
	log.Fatal(server.ListenAndServe())
}

// The SSE workload: a Datastar action. Its signals come as JSON in the
// `datastar` query parameter; the answer is a stream of Datastar events,
// each written and flushed as it is made (as Datastar's Go SDK does).
func datastar(w http.ResponseWriter, r *http.Request) {
	var signals struct {
		Count *uint32 `json:"count"`
	}
	err := json.Unmarshal([]byte(r.URL.Query().Get("datastar")), &signals)
	if err != nil || signals.Count == nil {
		http.Error(w, "bad signals", http.StatusBadRequest)
		return
	}
	count := uint64(*signals.Count) + 1
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	stream := http.NewResponseController(w)
	send := func(event string, format string, args ...any) bool {
		fmt.Fprintf(w, "event: %s\n"+format+"\n\n", append([]any{event}, args...)...)
		return stream.Flush() == nil
	}
	if !send("datastar-patch-signals", "data: signals {\"count\":%d}", count) {
		return
	}
	if !send("datastar-patch-elements", "data: elements <span id=\"count\">%d</span>", count) {
		return
	}
	for line := 1; line <= 8; line++ {
		if !send("datastar-patch-elements",
			"data: selector #log\ndata: mode append\ndata: elements <li>Event %d of 8</li>", line) {
			return
		}
	}
}

// The largest echoed body, as the other competitors.
const echoBytesMax = 1 << 20

// echoBuffers keeps request-body buffers between requests: a body of known
// length (Content-Length) is read straight into one, where io.ReadAll
// would grow a fresh buffer every time.
var echoBuffers = sync.Pool{New: func() any { buffer := make([]byte, 0, 64<<10); return &buffer }}

func echo(w http.ResponseWriter, r *http.Request) {
	body := http.MaxBytesReader(w, r.Body, echoBytesMax)
	if r.ContentLength < 0 || r.ContentLength > echoBytesMax {
		// Chunked, or too large: read it whole, MaxBytesReader refusing.
		bytes, err := io.ReadAll(body)
		if err != nil {
			http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(bytes)
		return
	}
	pooled := echoBuffers.Get().(*[]byte)
	defer echoBuffers.Put(pooled)
	if cap(*pooled) < int(r.ContentLength) {
		*pooled = make([]byte, 0, r.ContentLength)
	}
	buffer := (*pooled)[:r.ContentLength]
	if _, err := io.ReadFull(body, buffer); err != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(buffer) // copied into the connection's buffer before it returns
}
