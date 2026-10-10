package main

import (
	"strings"
	"testing"
)

// What a server sends, read back as responses: lengths, chunks, interim
// responses, a HEAD's head alone, and what cannot be read.
func TestParseResponses(t *testing.T) {
	raw := "HTTP/1.1 100 Continue\r\n\r\n" +
		"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc" +
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nde\r\n1;x=y\r\nf\r\n0\r\nT: 1\r\n\r\n"
	responses, unparsed := parseResponses([]byte(raw), false)
	if unparsed != "" || len(responses) != 2 {
		t.Fatalf("%d responses, unparsed %q", len(responses), unparsed)
	}
	if responses[0].Interim[0] != 100 || string(responses[0].Body) != "abc" || responses[0].Close {
		t.Fatalf("first: %+v", responses[0])
	}
	if string(responses[1].Body) != "def" || !responses[1].Close {
		t.Fatalf("second: %+v", responses[1])
	}
	head, _ := parseResponses([]byte("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n"), true)
	if len(head) != 1 || len(head[0].Body) != 0 {
		t.Fatalf("head: %+v", head)
	}
	_, unparsed = parseResponses([]byte("garbage"), false)
	if !strings.Contains(unparsed, "garbage") {
		t.Fatalf("unparsed %q", unparsed)
	}
	answer := DiffAnswer{Responses: responses, Closed: true}
	if got := answer.Summary(); got != `100+200 "abc", 200 "def" | closed` {
		t.Fatalf("summary %q", got)
	}
}

// Every case has a unique name.
func TestDiffCaseNames(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range diffCases {
		if seen[c.Name] {
			t.Fatalf("two cases named %q", c.Name)
		}
		seen[c.Name] = true
	}
}
