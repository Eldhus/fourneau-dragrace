package main

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
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
	if err := catalogPage(catalog).Render(r.Context(), w); err != nil {
		log.Print(err)
	}
}
