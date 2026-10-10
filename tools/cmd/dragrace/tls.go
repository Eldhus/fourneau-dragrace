package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// TLS for the race (RACING.md, TLS): one certificate a race, made here,
// the same for every competitor. ECDSA P-256, as Let's Encrypt issues by
// default and browsers meet most; self-signed, so oha takes it with
// --insecure (verifying a chain is the client's cost, not the server's).
const (
	certificateName = "tls-cert.pem"
	keyName         = "tls-key.pem"
)

// putCertificate makes the race's certificate and key and puts them in
// the server's home, where {cert} and {key} name them.
func putCertificate(ctx context.Context, target Target) error {
	certPEM, keyPEM, err := newCertificate(target.Address, time.Now())
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "dragrace-tls-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	for name, bytes := range map[string][]byte{certificateName: certPEM, keyName: keyPEM} {
		local := filepath.Join(dir, name)
		if err := os.WriteFile(local, bytes, 0o600); err != nil {
			return err
		}
		if err := target.Server.Put(ctx, local, target.ServerHome+"/"+name); err != nil {
			return fmt.Errorf("the certificate: %w", err)
		}
	}
	return nil
}

// newCertificate is a self-signed ECDSA P-256 certificate for address (an
// IP address, or a name), valid for a day around now, and its key, PEM.
func newCertificate(address string, now time.Time) (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	template := x509.Certificate{
		SerialNumber: big.NewInt(now.UnixNano()),
		Subject:      pkix.Name{CommonName: "fourneau-dragrace"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"fourneau-dragrace"},
	}
	if ip := net.ParseIP(address); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = append(template.DNSNames, address)
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

// validateTLS checks what a competitor's HTTPS agreed with a client
// offering what oha offers: HTTP/2 by ALPN, TLS 1.3, AES-128-GCM (every
// competitor is set to it: rustls clients ask for AES-256 first, which
// some servers follow), X25519. "" when it does. The line curl prints for
// it is logged, so a run says what each competitor agreed.
func validateTLS(ctx context.Context, target Target, url string) string {
	script := curlFor(tlsMode) + "-v -o /dev/null -w 'version %{http_version}\\n' " +
		url + "/plaintext 2>&1 | grep -E 'SSL connection using|^version '"
	text, err := target.Loader.Shell(ctx, script)
	if err != nil {
		return "TLS: " + err.Error()
	}
	return checkTLS(text)
}

// checkTLS reads validateTLS's lines.
func checkTLS(text string) string {
	agreed := ""
	version := ""
	for _, line := range strings.Split(text, "\n") {
		if _, after, found := strings.Cut(line, "SSL connection using "); found {
			agreed = strings.TrimSpace(after)
		}
		if after, found := strings.CutPrefix(line, "version "); found {
			version = strings.TrimSpace(after)
		}
	}
	if version != "2" {
		return fmt.Sprintf("TLS: HTTP/%s by ALPN, not HTTP/2", version)
	}
	log.Printf("    TLS agreed: %s", agreed)
	lower := strings.ToLower(agreed)
	switch {
	case agreed == "":
		return "" // a curl that does not say: HTTP/2 was checked, the rest is logged
	case !strings.Contains(lower, "tlsv1.3"):
		return "TLS: not TLS 1.3: " + agreed
	case !strings.Contains(lower, "aes_128_gcm"):
		return "TLS: not AES-128-GCM: " + agreed
	case !strings.Contains(lower, "/ x25519 /"):
		return "TLS: not X25519: " + agreed
	}
	return ""
}
