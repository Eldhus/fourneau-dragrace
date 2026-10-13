package main

import (
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestNewCertificate(t *testing.T) {
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	certPEM, keyPEM, err := newCertificate("10.0.0.7", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tls.X509KeyPair(certPEM, keyPEM); err != nil {
		t.Fatalf("the pair does not load: %v", err)
	}
	block, _ := pem.Decode(certPEM)
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cert.PublicKey.(*ecdsa.PublicKey); !ok {
		t.Errorf("not ECDSA: %T", cert.PublicKey)
	}
	if len(cert.IPAddresses) != 1 || cert.IPAddresses[0].String() != "10.0.0.7" {
		t.Errorf("IP addresses %v", cert.IPAddresses)
	}
	if !cert.NotBefore.Before(now) || !cert.NotAfter.After(now) {
		t.Errorf("not valid now: %v to %v", cert.NotBefore, cert.NotAfter)
	}
}

func TestCheckTLS(t *testing.T) {
	good := "* SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256 / x25519 / id-ecPublicKey\nversion 2"
	for text, want := range map[string]string{
		good: "",
		// An older curl's spelling.
		strings.Replace(good, "x25519", "X25519", 1):                 "",
		strings.Replace(good, "version 2", "version 1.1", 1):         "TLS: HTTP/1.1 by ALPN, not HTTP/2",
		strings.Replace(good, "AES_128", "AES_256", 1):               "TLS: not AES-128-GCM",
		strings.Replace(good, "/ x25519 /", "/ X25519MLKEM768 /", 1): "TLS: not X25519",
		// A curl that does not say: HTTP/2 is still checked.
		"version 2": "",
	} {
		if got := checkTLS(text); !strings.HasPrefix(got, want) || (want == "" && got != "") {
			t.Errorf("checkTLS(%q) = %q, want %q", text, got, want)
		}
	}
}

func TestOhaCommandOverTLS(t *testing.T) {
	race := Race{Port: 8080}
	target := Target{Address: "10.0.0.7", LoaderHome: "/home/x"}
	h2 := Workload{Name: "templates-tls", Method: "GET", Path: "/menu", Connections: 128,
		Keepalive: true, HTTP2: true, Streams: 2, TLS: true}
	command := ohaCommand(race, h2, target, nil, 20)
	for _, want := range []string{" --http2 -p 2", " --insecure", " https://10.0.0.7:8080/menu"} {
		if !strings.Contains(command, want) {
			t.Errorf("%q lacks %q", command, want)
		}
	}
	churn := Workload{Name: "churn-tls", Method: "GET", Path: "/plaintext", Connections: 64, TLS: true}
	command = ohaCommand(race, churn, target, nil, 20)
	if strings.Contains(command, "--http2") || !strings.Contains(command, "--disable-keepalive") {
		t.Errorf("churn over TLS: %q", command)
	}
	plain := Workload{Name: "plaintext", Method: "GET", Path: "/plaintext", Connections: 256,
		Keepalive: true}
	command = ohaCommand(race, plain, target, nil, 20)
	if strings.Contains(command, "--insecure") || !strings.Contains(command, " http://10.0.0.7") {
		t.Errorf("plain: %q", command)
	}
	// RealWorld's parts over TLS, as its twin over HTTP/1.1 but for these.
	part := Part{Name: "list", Method: "GET", Path: "/api/articles", Share: 0.5}
	conduit := Workload{Name: "conduit-tls", Method: "MIXED", Connections: 128, Keepalive: true,
		HTTP2: true, Streams: 2, TLS: true, Mixed: &Mixed{Parts: []Part{part}}}
	command = partCommand(race, conduit, target, part, 500, 60)
	for _, want := range []string{" -c 64 ", " --http2 -p 2", " --insecure", " 'https://10[.]0[.]0[.]7:8080/api/articles'"} {
		if !strings.Contains(command, want) {
			t.Errorf("%q lacks %q", command, want)
		}
	}
	conduit.HTTP2, conduit.TLS = false, false
	command = partCommand(race, conduit, target, part, 500, 60)
	if strings.Contains(command, "--insecure") || strings.Contains(command, "--http2") {
		t.Errorf("RealWorld plain: %q", command)
	}
}

func TestOffers(t *testing.T) {
	plain := Competitor{Name: "basic-webserver"}
	secure := Competitor{Name: "go", Run: RunSpec{TLS: &RunTLS{}}}
	tlsWorkload := Workload{TLS: true}
	if plain.offers(tlsWorkload) || !plain.offers(Workload{}) {
		t.Error("a competitor without TLS sits out the TLS workloads only")
	}
	if !secure.offers(tlsWorkload) {
		t.Error("a competitor with TLS races them")
	}
	if validKey("go", tlsMode) == validKey("go", plainMode) {
		t.Error("each mode is checked on its own")
	}
}

// A test is a workload a variant, named as the races before variants named
// them, in the site's order whatever race.json's.
func TestExpand(t *testing.T) {
	test := Test{Name: "plaintext", Title: "Plaintext", Summary: "one line", Detail: "more",
		Method: "GET", Path: "/plaintext", Keepalive: true, Variants: []Variant{
			{Protocol: "tls", Connections: 32, Streams: 8},
			{Protocol: "http1", Connections: 256},
			{Protocol: "h2c", Connections: 32, Streams: 8}}}
	workloads, err := test.expand()
	if err != nil {
		t.Fatal(err)
	}
	want := []Workload{
		{Name: "plaintext", Title: "Plaintext", Protocol: "http1", Connections: 256},
		{Name: "plaintext-h2", Title: "Plaintext, HTTP/2 (h2c)", Protocol: "h2c", Connections: 32,
			HTTP2: true, Streams: 8},
		{Name: "plaintext-tls", Title: "Plaintext, HTTP/2 + TLS", Protocol: "tls", Connections: 32,
			HTTP2: true, Streams: 8, TLS: true},
	}
	for i, w := range want {
		w.Test, w.Summary, w.Method, w.Path, w.Keepalive = "plaintext", "one line", "GET", "/plaintext", true
		if i >= len(workloads) || !reflect.DeepEqual(workloads[i], w) {
			t.Errorf("got %+v, want %+v", workloads, want)
			break
		}
	}
	churn := Test{Name: "churn", Title: "Churn", Summary: "s", Detail: "d", Variants: []Variant{
		{Protocol: "http1", Connections: 64}, {Protocol: "tls", Connections: 64}}}
	if got, err := churn.expand(); err != nil || got[1].HTTP2 || !got[1].TLS || got[1].Title != "Churn, HTTP/1.1 + TLS" {
		t.Errorf("churn over TLS is HTTP/1.1: %+v, %v", got, err)
	}
	http1 := Variant{Protocol: "http1", Connections: 256}
	for _, variants := range [][]Variant{
		{{Protocol: "tls", Connections: 64}},
		{http1, http1},
		{http1, {Protocol: "h3", Connections: 1}},
		{http1, {Protocol: "h2c", Connections: 32}},
		{{Protocol: "http1", Connections: 256, Streams: 2}},
		{{Protocol: "http1"}},
	} {
		wrong := Test{Name: "t", Summary: "s", Detail: "d", Keepalive: true, Variants: variants}
		if _, err := wrong.expand(); err == nil {
			t.Errorf("accepted %+v", variants)
		}
	}
	unkept := Test{Name: "t", Summary: "s", Detail: "d", Variants: []Variant{http1, {Protocol: "h2c", Connections: 32, Streams: 8}}}
	wordless := Test{Name: "t", Summary: "s", Keepalive: true, Variants: []Variant{http1}}
	if _, err := unkept.expand(); err == nil {
		t.Error("HTTP/2 without keep-alive")
	}
	if _, err := wordless.expand(); err == nil {
		t.Error("a test without a detail")
	}
}

// race.json as committed: every test raced over HTTP/1.1 and TLS, plaintext over h2c too (HTTP/2's cost apart from TLS's),
// each variant the same requests in flight as HTTP/1.1's connections: the
// same test, carried another way.
func TestRaceVariants(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range race.Tests {
		workloads, _ := test.expand()
		want := []string{"http1", "tls"}
		if test.Name == "plaintext" {
			want = []string{"http1", "h2c", "tls"}
		}
		var got []string
		for _, workload := range workloads {
			got = append(got, workload.Protocol)
			if inFlight := workload.Connections * max(1, workload.Streams); inFlight != workloads[0].Connections {
				t.Errorf("%s: %d requests in flight, HTTP/1.1 %d", workload.Name, inFlight, workloads[0].Connections)
			}
		}
		if !slices.Equal(got, want) {
			t.Errorf("%s: variants %v, want %v", test.Name, got, want)
		}
	}
}
