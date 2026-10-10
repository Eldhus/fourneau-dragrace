package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// dragrace diff: the same requests, byte for byte, to several competitors,
// and where their answers differ (fourneau's M11, "second opinions"). Each
// case is sent on a new connection; the answer is read until the server
// closes or is idle for a second. What is compared: each response's
// status, whether the connection was closed after, and the body; never the
// Date or Server headers, or the reason phrase. Every divergence is then
// fixed or written down as a decision, in fourneau's docs/differential.md.

// DiffCase is one request (or several, pipelined), as raw bytes.
type DiffCase struct {
	Name  string
	About string
	Bytes string
}

// diffCases is the corpus: where HTTP/1.1 parsers are known to differ, and
// where request smuggling lives (RFC 9112 §6.3, §11.2).
var diffCases = []DiffCase{
	{"plain", "a plain GET", "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"http10-no-host", "HTTP/1.0, no Host", "GET /plaintext HTTP/1.0\r\n\r\n"},
	{"http11-no-host", "HTTP/1.1 without Host (RFC 9112 §3.2: 400)", "GET /plaintext HTTP/1.1\r\n\r\n"},
	{"two-hosts", "two Host fields", "GET /plaintext HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"},
	{"host-space", "a Host with a space inside", "GET /plaintext HTTP/1.1\r\nHost: a b\r\n\r\n"},
	{"cl-and-te", "Content-Length and Transfer-Encoding both (smuggling)",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"cl-twice-differ", "two Content-Lengths that differ",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd"},
	{"cl-twice-same", "two Content-Lengths alike",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc"},
	{"cl-list", "Content-Length: 3, 3",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3, 3\r\n\r\nabc"},
	{"cl-plus", "Content-Length: +3", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: +3\r\n\r\nabc"},
	{"cl-leading-zero", "Content-Length: 03", "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 03\r\n\r\nabc"},
	{"cl-huge", "Content-Length past 2^64",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999999\r\n\r\nabc"},
	{"cl-too-large", "Content-Length past every limit (100 MB)",
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100000000\r\n\r\nabc"},
	{"chunked", "a chunked body", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"chunked-upper-hex", "chunk sizes in capitals", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nA\r\n0123456789\r\n0\r\n\r\n"},
	{"chunked-extension", "a chunk extension", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3;name=value\r\nabc\r\n0\r\n\r\n"},
	{"chunked-trailer", "a trailer section", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Sum: 1\r\n\r\n"},
	{"chunked-bad-size", "a chunk size that is not hex", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n"},
	{"chunked-bare-lf", "chunk lines ended by a bare LF", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\nabc\n0\n\n"},
	{"te-gzip-chunked", "Transfer-Encoding: gzip, chunked", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"te-chunked-gzip", "Transfer-Encoding: chunked, gzip (chunked not last)", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"te-identity", "Transfer-Encoding: identity", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\nContent-Length: 3\r\n\r\nabc"},
	{"te-capitals", "Transfer-Encoding: Chunked", "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: Chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"te-http10", "chunked in HTTP/1.0", "POST /echo HTTP/1.0\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"},
	{"bare-lf", "a head ended by bare LFs", "GET /plaintext HTTP/1.1\nHost: x\n\n"},
	{"space-before-colon", "Host : x (RFC 9112 §5.1: 400)", "GET /plaintext HTTP/1.1\r\nHost : x\r\n\r\n"},
	{"obs-fold", "a folded header line", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: one\r\n two\r\n\r\n"},
	{"bad-name", "a header name with @", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX@A: 1\r\n\r\n"},
	{"nul-in-value", "a NUL in a value", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: a\x00b\r\n\r\n"},
	{"cr-in-value", "a bare CR in a value", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: a\rb\r\n\r\n"},
	{"empty-line-first", "an empty line before the request (RFC 9112 §2.2 may skip it)", "\r\nGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"absolute-form", "an absolute-form target", "GET http://x/plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"absolute-form-other-host", "an absolute-form target naming another host than Host", "GET http://y/plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"asterisk", "OPTIONS *", "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"asterisk-get", "GET * (only OPTIONS may)", "GET * HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"connect", "CONNECT authority-form", "CONNECT x:443 HTTP/1.1\r\nHost: x:443\r\n\r\n"},
	{"unknown-method", "a method no one knows", "BREW /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"lower-method", "a method in lower case", "get /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"version-12", "HTTP/1.2", "GET /plaintext HTTP/1.2\r\nHost: x\r\n\r\n"},
	{"version-20", "HTTP/2.0 on an HTTP/1 line", "GET /plaintext HTTP/2.0\r\nHost: x\r\n\r\n"},
	{"version-lower", "http/1.1 in lower case", "GET /plaintext http/1.1\r\nHost: x\r\n\r\n"},
	{"two-spaces", "two spaces after the method", "GET  /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"target-space", "a space in the target", "GET /plain text HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"long-target", "a 10,000-byte target", "GET /" + strings.Repeat("a", 10000) + " HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"long-header", "a 20,000-byte header", "GET /plaintext HTTP/1.1\r\nHost: x\r\nX-A: " + strings.Repeat("a", 20000) + "\r\n\r\n"},
	{"many-headers", "200 headers", "GET /plaintext HTTP/1.1\r\nHost: x\r\n" + strings.Repeat("X-A: 1\r\n", 200) + "\r\n"},
	{"pipelined", "two GETs in one write", "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\nGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"head", "HEAD: the head alone", "HEAD /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"get-with-body", "a GET with a body", "GET /plaintext HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"expect-continue", "Expect: 100-continue, the body sent anyway", "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabc"},
	{"expect-other", "Expect: something else (RFC 9110 §10.1.1: 417)", "POST /echo HTTP/1.1\r\nHost: x\r\nExpect: other\r\nContent-Length: 3\r\n\r\nabc"},
	{"connection-close", "Connection: close", "GET /plaintext HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"},
	{"http10-keepalive", "HTTP/1.0 asking to keep alive", "GET /plaintext HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /plaintext HTTP/1.0\r\n\r\n"},
	{"not-found", "a path no one serves", "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"query", "a query string", "GET /plaintext?a=1 HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"dot-segments", "/./plaintext", "GET /./plaintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"percent-path", "/%70laintext (a percent-encoded p)", "GET /%70laintext HTTP/1.1\r\nHost: x\r\n\r\n"},
	{"method-on-get-route", "POST to a GET route", "POST /plaintext HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"},
	{"garbage", "not HTTP at all", "\x16\x03\x01\x00\x05hello"},
}

// DiffResponse is one response as compared.
type DiffResponse struct {
	Status int
	Close  bool // the response said Connection: close
	Body   []byte
	// Interim responses (1xx) before it.
	Interim []int
}

// DiffAnswer is everything one server sent for one case.
type DiffAnswer struct {
	Responses []DiffResponse
	// The server closed the connection (EOF) rather than going idle.
	Closed bool
	// What could not be read as responses: the server's bytes as sent.
	Unparsed string
}

// Summary is the answer in a line: what is compared.
func (answer DiffAnswer) Summary() string {
	var parts []string
	for _, response := range answer.Responses {
		part := strconv.Itoa(response.Status)
		for _, interim := range response.Interim {
			part = strconv.Itoa(interim) + "+" + part
		}
		// An error's body is each stack's own words: its status is
		// what is compared.
		if len(response.Body) > 0 && response.Status < 400 {
			part += " " + bodyDigest(response.Body)
		}
		parts = append(parts, part)
	}
	if answer.Unparsed != "" {
		parts = append(parts, fmt.Sprintf("unparsed %q", clip(answer.Unparsed, 24)))
	}
	if len(parts) == 0 {
		parts = append(parts, "nothing")
	}
	end := "open"
	if answer.Closed {
		end = "closed"
	}
	return strings.Join(parts, ", ") + " | " + end
}

// bodyDigest shows a short body as itself, a long one by length and hash.
func bodyDigest(body []byte) string {
	if len(body) <= 16 && isPrintable(body) {
		return fmt.Sprintf("%q", body)
	}
	sum := sha256.Sum256(body)
	return fmt.Sprintf("%dB:%x", len(body), sum[:3])
}

func isPrintable(text []byte) bool {
	for _, b := range text {
		if b < 0x20 || b > 0x7e {
			return false
		}
	}
	return true
}

func clip(text string, n int) string {
	if len(text) <= n {
		return text
	}
	return text[:n] + "…"
}

// parseResponses reads every response in what a server sent. Bodies by
// Content-Length, chunked, or to the end; a HEAD's response has none.
func parseResponses(raw []byte, head bool) ([]DiffResponse, string) {
	reader := bufio.NewReader(bytes.NewReader(raw))
	var responses []DiffResponse
	var interim []int
	for len(responses) < 16 {
		if _, err := reader.Peek(1); err != nil {
			return responses, ""
		}
		status, headers, err := readHead(reader)
		if err != nil {
			rest, _ := io.ReadAll(reader)
			return responses, err.Error() + ": " + string(rest)
		}
		if status >= 100 && status < 200 {
			interim = append(interim, status)
			continue
		}
		response := DiffResponse{Status: status, Interim: interim,
			Close: hasToken(headers["connection"], "close")}
		interim = nil
		body, err := readBody(reader, headers, head || status == 204 || status == 304)
		if err != nil {
			return append(responses, response), err.Error()
		}
		response.Body = body
		responses = append(responses, response)
	}
	return responses, ""
}

func readHead(reader *bufio.Reader) (int, map[string]string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return 0, nil, fmt.Errorf("a cut status line %q", clip(line, 40))
	}
	fields := strings.SplitN(strings.TrimRight(line, "\r\n"), " ", 3)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/1.") {
		return 0, nil, fmt.Errorf("not a status line %q", clip(line, 40))
	}
	status, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, nil, fmt.Errorf("a status %q", fields[1])
	}
	headers := map[string]string{}
	for range 1000 {
		line, err := reader.ReadString('\n')
		if err != nil {
			return 0, nil, errors.New("a cut head")
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			return status, headers, nil
		}
		name, value, found := strings.Cut(line, ":")
		if !found {
			return 0, nil, fmt.Errorf("a header line %q", clip(line, 40))
		}
		key := strings.ToLower(name)
		if previous, ok := headers[key]; ok {
			value = previous + "," + value
		}
		headers[key] = strings.TrimSpace(value)
	}
	return 0, nil, errors.New("a head of 1,000 lines")
}

func hasToken(value, token string) bool {
	for _, part := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

func readBody(reader *bufio.Reader, headers map[string]string, none bool) ([]byte, error) {
	if none {
		return nil, nil
	}
	if hasToken(headers["transfer-encoding"], "chunked") {
		return readChunked(reader)
	}
	if length, ok := headers["content-length"]; ok {
		n, err := strconv.Atoi(length)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("a content-length %q", length)
		}
		body := make([]byte, n)
		if _, err := io.ReadFull(reader, body); err != nil {
			return body, errors.New("a body cut short")
		}
		return body, nil
	}
	return io.ReadAll(reader)
}

func readChunked(reader *bufio.Reader) ([]byte, error) {
	var body []byte
	for range 100000 {
		line, err := reader.ReadString('\n')
		if err != nil {
			return body, errors.New("a cut chunk size")
		}
		size, _, _ := strings.Cut(strings.TrimRight(line, "\r\n"), ";")
		n, err := strconv.ParseInt(strings.TrimSpace(size), 16, 64)
		if err != nil || n < 0 {
			return body, fmt.Errorf("a chunk size %q", clip(line, 20))
		}
		if n == 0 {
			for range 100 { // the trailer section, to its empty line
				line, err := reader.ReadString('\n')
				if err != nil || strings.TrimRight(line, "\r\n") == "" {
					return body, nil
				}
			}
			return body, errors.New("a long trailer")
		}
		chunk := make([]byte, n+2)
		if _, err := io.ReadFull(reader, chunk); err != nil {
			return body, errors.New("a chunk cut short")
		}
		body = append(body, chunk[:n]...)
	}
	return body, errors.New("100,000 chunks")
}

// exchange sends a case and reads its answer: to the server's close, or
// a second of silence once something came (two before anything).
func exchange(address string, request string) (DiffAnswer, error) {
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return DiffAnswer{}, err
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(request)); err != nil {
		return DiffAnswer{Closed: true}, nil
	}
	var raw []byte
	buffer := make([]byte, 64*1024)
	closed := false
	for len(raw) < 4<<20 {
		wait := 2 * time.Second
		if len(raw) > 0 {
			wait = time.Second
		}
		conn.SetReadDeadline(time.Now().Add(wait))
		n, err := conn.Read(buffer)
		raw = append(raw, buffer[:n]...)
		if err != nil {
			var timeout net.Error
			closed = !(errors.As(err, &timeout) && timeout.Timeout())
			break
		}
	}
	head := strings.HasPrefix(request, "HEAD ")
	responses, unparsed := parseResponses(raw, head)
	return DiffAnswer{Responses: responses, Closed: closed, Unparsed: unparsed}, nil
}

func commandDiff(ctx context.Context, root string, args []string) error {
	flags := flag.NewFlagSet("diff", flag.ExitOnError)
	names := flags.String("competitors", "fourneau-zig,go,axum", "comma-separated")
	only := flags.String("cases", "", "comma-separated (default: all)")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	race.Competitors = strings.Split(*names, ",")
	race.Workloads = nil // no SSE check, no conduit database
	cases := selectCases(*only)
	tools, err := loadToolchain(ctx, root)
	if err != nil {
		return err
	}
	competitors, err := loadCompetitors(root, race.Competitors)
	if err != nil {
		return err
	}
	if err := buildAll(ctx, root, tools, competitors); err != nil {
		return err
	}
	target := Target{Server: LocalMachine{}, Loader: LocalMachine{}, ServerHome: outDir(root),
		LoaderHome: filepath.Join(outDir(root), "loader"), Address: "127.0.0.1"}
	answers := map[string]map[string]DiffAnswer{}
	for _, competitor := range competitors {
		got, err := diffCompetitor(ctx, race, competitor, target, cases)
		if err != nil {
			return err
		}
		answers[competitor.Name] = got
	}
	report := diffReport(race.Competitors, cases, answers)
	fmt.Print(report)
	path := filepath.Join(outDir(root), "diff.md")
	return os.WriteFile(path, []byte(report), 0o644)
}

func selectCases(only string) []DiffCase {
	if only == "" {
		return diffCases
	}
	var chosen []DiffCase
	for _, name := range strings.Split(only, ",") {
		for _, c := range diffCases {
			if c.Name == name {
				chosen = append(chosen, c)
			}
		}
	}
	return chosen
}

func diffCompetitor(ctx context.Context, race Race, competitor Competitor, target Target,
	cases []DiffCase) (map[string]DiffAnswer, error) {
	pid, err := startServer(ctx, race, competitor, target)
	if err != nil {
		return nil, err
	}
	defer stopServer(ctx, target, pid)
	if err := waitReady(ctx, race, target); err != nil {
		return nil, fmt.Errorf("%s: %s", competitor.Name, whyNotReady(ctx, competitor, target, pid))
	}
	address := fmt.Sprintf("%s:%d", target.Address, race.Port)
	got := map[string]DiffAnswer{}
	for _, c := range cases {
		answer, err := exchange(address, c.Bytes)
		if err != nil {
			return nil, fmt.Errorf("%s, %s: %w", competitor.Name, c.Name, err)
		}
		got[c.Name] = answer
	}
	return got, nil
}

// diffReport is a table of every case, the divergent ones marked.
func diffReport(names []string, cases []DiffCase, answers map[string]map[string]DiffAnswer) string {
	var report strings.Builder
	differ := 0
	report.WriteString("| case | " + strings.Join(names, " | ") + " |\n|---|")
	report.WriteString(strings.Repeat("---|", len(names)) + "\n")
	for _, c := range cases {
		row := make([]string, len(names))
		same := true
		for i, name := range names {
			row[i] = answers[name][c.Name].Summary()
			if row[i] != row[0] {
				same = false
			}
		}
		mark := ""
		if !same {
			mark = " **≠**"
			differ++
		}
		fmt.Fprintf(&report, "| `%s`%s: %s | %s |\n", c.Name, mark, c.About, strings.Join(row, " | "))
	}
	fmt.Fprintf(&report, "\n%d cases, %d answered differently.\n", len(cases), differ)
	return report.String()
}
