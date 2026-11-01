package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
)

// The catalog workload: a bigger page from html/template, parsed once and
// executed per request: sections over a record, lists nested in lists, a
// table of 256 rows, conditions, empty lists, raw HTML and formatting
// functions. The reference is workloads/catalog.html.
var catalogPage = template.Must(template.New("catalog").Funcs(template.FuncMap{
	"kr":     kr,
	"plural": plural,
}).Parse(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{.Title}}</title></head>
<body>
{{/* A comment: nothing of it is written. */ -}}
<h1>{{.Title}}</h1>
<p>{{.Note}}</p>
{{with .Shop}}<p>{{.Name}}, {{$.Shop.City}}{{if .Open}} (open){{end}}</p>
{{end -}}
{{if not .Closed}}<p>Open today.</p>{{end}}
{{if not .Specials}}<p>No specials.</p>{{end}}
<p>{{plural (len .Groups) "group" "groups"}}, {{len .Rows}} rows</p>
{{range .Groups}}<h2>{{.Name}}</h2><p>{{range .Members}}{{.}};{{end}}</p>
{{end -}}
<table>
{{range .Rows}}<tr{{if .Hot}} class="hot"{{end}}><td>{{.ID}}<td>{{.Name}}<td>{{.Stock}}<td>{{range .Tags}}<i>{{.}}</i>{{else}}-{{end}}<td>{{kr .Price}} {{$.Currency}}
{{end -}}
</table>
</body>
</html>
`))

type Catalog struct {
	Title    string
	Note     template.HTML
	Currency string
	Shop     Shop
	Closed   bool
	Specials []string
	Groups   []Group
	Rows     []Row
}

type Shop struct {
	Name, City string
	Open       bool
}

type Group struct {
	Name    string
	Members []string
}

type Row struct {
	ID    uint32
	Name  string
	Price uint32
	Stock int32
	Hot   bool
	Tags  []string
}

// The catalog's names: markup, quotes and accents, each escaped as printed.
var names = []string{"Roux", "Skyr & ber", "Crème", "<b>Stew</b>", "Hákarl", "Kjöt \"s\"", "O'Brien", "Pylsa"}

// The catalog's data, as race.json's catalog test defines it.
var catalog = func() Catalog {
	c := Catalog{
		Title:    `Catalog <&> "one" 'two'`,
		Note:     "<em>Fresh</em> &amp; local",
		Currency: "kr",
		Shop:     Shop{Name: "Eldhús", City: "Reykjavík", Open: true},
		Specials: []string{},
	}
	for i := 0; i < 256; i++ {
		tags := [][]string{{}, {"veg"}, {"veg", "gf"}}[i%3]
		c.Rows = append(c.Rows, Row{
			ID:    uint32(i + 1),
			Name:  names[i%8],
			Price: uint32(500 + (i*7919)%20000),
			Stock: int32((i*13)%50 - 10),
			Hot:   i%7 == 0,
			Tags:  tags,
		})
	}
	for k := 0; k < 6; k++ {
		c.Groups = append(c.Groups, Group{
			Name:    fmt.Sprintf("Group %d", k+1),
			Members: []string{names[k%8], names[(k+1)%8], names[(k+2)%8]},
		})
	}
	return c
}()

// A price in hundredths: 12.05.
func kr(hundredths uint32) string {
	return fmt.Sprintf("%d.%02d", hundredths/100, hundredths%100)
}

// A count and the noun that fits it: 1 group, 6 groups.
func plural(count int, one, many string) string {
	if count == 1 {
		return fmt.Sprintf("%d %s", count, one)
	}
	return fmt.Sprintf("%d %s", count, many)
}

func catalogHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := catalogPage.Execute(w, catalog); err != nil {
		log.Print(err)
	}
}
