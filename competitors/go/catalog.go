package main

import (
	"fmt"
	"log"
	"net/http"
)

// The catalog workload's template is catalog.templ, compiled to Go by templ
// (catalog_templ.go, generated: `go tool templ generate`).

type Catalog struct {
	Title    string
	Note     string // HTML, written raw
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
	if err := catalogPage(catalog).Render(r.Context(), w); err != nil {
		log.Print(err)
	}
}
