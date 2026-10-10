package main

import (
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
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
	command := ohaCommand(race, h2, target, nil, LoadShape{Seconds: 20})
	for _, want := range []string{" --http2 -p 2", " --insecure", " https://10.0.0.7:8080/menu"} {
		if !strings.Contains(command, want) {
			t.Errorf("%q lacks %q", command, want)
		}
	}
	churn := Workload{Name: "churn-tls", Method: "GET", Path: "/plaintext", Connections: 64, TLS: true}
	command = ohaCommand(race, churn, target, nil, LoadShape{Seconds: 20})
	if strings.Contains(command, "--http2") || !strings.Contains(command, "--disable-keepalive") {
		t.Errorf("churn over TLS: %q", command)
	}
	plain := Workload{Name: "plaintext", Method: "GET", Path: "/plaintext", Connections: 256,
		Keepalive: true}
	command = ohaCommand(race, plain, target, nil, LoadShape{Seconds: 20})
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

// race.json as committed: every section known, and both flavours of HTTP
// race the same tests (owner, 2026-10-10): each HTTP/1.1 workload has its
// twin over TLS, open loop the same. No share ladder: RealWorld's climb
// is the open loop.
func TestRaceSections(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]Workload{}
	for _, workload := range race.Workloads {
		byName[workload.Name] = workload
		if workload.TLS != (workload.section() == "tls") {
			t.Errorf("%s: TLS and the tls section go together", workload.Name)
		}
		if workload.Ladder {
			t.Errorf("%s: a share ladder", workload.Name)
		}
	}
	twins := 0
	for _, workload := range race.Workloads {
		if workload.section() != "http1" {
			continue
		}
		twin, found := byName[workload.Name+"-tls"]
		if !found {
			t.Errorf("%s has no twin over TLS", workload.Name)
			continue
		}
		twins++
		if twin.Path != workload.Path || twin.Method != workload.Method ||
			(twin.Mixed == nil) != (workload.Mixed == nil) {
			t.Errorf("%s-tls is not %s over TLS", workload.Name, workload.Name)
		}
	}
	if twins+1 != len(race.Workloads)-twins { // and plaintext-h2, h2c's own
		t.Errorf("%d twins of %d workloads", twins, len(race.Workloads))
	}
}
