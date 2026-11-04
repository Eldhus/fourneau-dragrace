package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The catalog workload: a bigger page from html/template, parsed once and
// executed per request: sections over a record, lists nested in lists, a
// list of 96 rows, conditions, empty lists, raw HTML and formatting
// functions. The reference is workloads/templates.html; the template's
// line breaks are the reference's, so `{{end}}` opens the next line.
var catalogPage = template.Must(template.New("catalog").Funcs(template.FuncMap{
	"kr":     kr,
	"plural": plural,
	"pct":    pct,
	"level":  level,
	"stock":  stock,
	"tags":   tags,
	"sale":   sale,
	"date":   date,
	"weight": weight,
}).Parse(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{.Title}}</title></head>
<body>
<h1>{{.Title}}</h1>
<p>{{.Note}}</p>
<p>{{.Shop.Name}}, {{.Shop.City}} {{if .Shop.Open}}(open){{else}}(closed){{end}}</p>
{{if not .Closed}}<p>Open today.</p>
{{end}}{{if not .Specials}}<p>No specials.</p>
{{end}}<ul>
{{range .Offers}}<li>{{.What}}: {{pct .Off}} off</li>
{{end}}</ul>
{{if not .Offers}}<p>No offers.</p>
{{end}}<p>{{plural (len .Groups) "group" "groups"}}, {{plural (len .Rows) "row" "rows"}}, {{kr .Total}} {{.Currency}} in stock</p>
{{range .Groups}}<h2>{{.Name}}</h2><p>{{range .Members}}{{.}};{{end}}</p>
{{end}}<ul>
{{range .Rows}}<li class="{{level .Stock}}{{if .Hot}} hot{{end}}">{{.ID}} {{.Name}}, {{stock .Stock}}{{tags .Tags}}, {{if .OnSale}}<s>{{kr .Price}}</s> {{kr (sale .Price .Discount)}}{{else}}{{kr .Price}}{{end}}, {{date .Added}}, {{weight .Grams}}</li>
{{end}}</ul>
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
	Offers   []Offer
	Total    uint32
	Groups   []Group
	Rows     []Row
}

type Shop struct {
	Name, City string
	Open       bool
}

type Offer struct {
	What string
	Off  uint8
}

type Group struct {
	Name    string
	Members []string
}

type Row struct {
	ID       uint32
	Name     string
	Price    uint32
	Discount uint8
	OnSale   bool
	Stock    int32
	Hot      bool
	Tags     []string
	Added    uint16
	Grams    uint32
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
		Offers:   []Offer{{"Soup of the day", 10}, {"Bread & butter", 25}, {"Coffee <hot>", 5}},
	}
	for i := 0; i < 96; i++ {
		tags := [][]string{{}, {"veg"}, {"veg", "gf"}}[i%3]
		discount := uint8((i * 37) % 40)
		price := uint32(500 + (i*7919)%20000)
		c.Total += price
		c.Rows = append(c.Rows, Row{
			ID:       uint32(i + 1),
			Name:     names[i%8],
			Price:    price,
			Discount: discount,
			OnSale:   discount > 0,
			Stock:    int32((i*13)%50 - 10),
			Hot:      i%7 == 0,
			Tags:     tags,
			Added:    uint16((i * 53) % 365),
			Grams:    uint32(50 + (i*997)%5000),
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

// A percentage: 10%.
func pct(percent uint8) string {
	return strconv.Itoa(int(percent)) + "%"
}

// A stock's level, the row's class: out, low (under ten), ok.
func level(stock int32) string {
	switch {
	case stock <= 0:
		return "out"
	case stock < 10:
		return "low"
	}
	return "ok"
}

// A stock as written: out, 3 left, 16.
func stock(count int32) string {
	switch {
	case count <= 0:
		return "out"
	case count < 10:
		return fmt.Sprintf("%d left", count)
	}
	return strconv.FormatInt(int64(count), 10)
}

// A row's tags after its stock, each after a space; a dash for none.
func tags(tags []string) string {
	if len(tags) == 0 {
		return " -"
	}
	return " " + strings.Join(tags, " ")
}

// A price after a discount in percent, in hundredths, rounded down.
func sale(price uint32, off uint8) uint32 {
	return price - price*uint32(off)/100
}

// A day of 2026 (0 is January 1) as MM-DD.
func date(day uint16) string {
	return time.Date(2026, time.January, 1+int(day), 0, 0, 0, 0, time.UTC).Format("01-02")
}

// A weight in grams: 350 g, or 1.25 kg from a kilogram up.
func weight(grams uint32) string {
	if grams < 1000 {
		return fmt.Sprintf("%d g", grams)
	}
	return fmt.Sprintf("%d.%02d kg", grams/1000, (grams%1000)/10)
}

func catalogHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := catalogPage.Execute(w, catalog); err != nil {
		log.Print(err)
	}
}
