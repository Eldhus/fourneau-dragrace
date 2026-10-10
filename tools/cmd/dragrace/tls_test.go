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

// race.json as committed: every section known, the ladders where the
// site draws them.
func TestRaceSections(t *testing.T) {
	race, err := loadRace("../../..")
	if err != nil {
		t.Fatal(err)
	}
	ladders := []string{}
	for _, workload := range race.Workloads {
		if workload.TLS != (workload.section() == "tls") {
			t.Errorf("%s: TLS and the tls section go together", workload.Name)
		}
		if workload.Ladder {
			ladders = append(ladders, workload.Name)
		}
	}
	if strings.Join(ladders, ",") != "templates,templates-tls,sse-tls" {
		t.Errorf("ladders %v", ladders)
	}
}
