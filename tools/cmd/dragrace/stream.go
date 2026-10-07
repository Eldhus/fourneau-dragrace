package main

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// The SSE workload's contract is about how the stream is sent, not only
// what it says: chunked, no Content-Length, each event its own chunk. A
// server that renders the whole stream and sends it as one body would do
// the templates workload with another content type; requiring a chunk per
// event means each competitor's streaming path is what races. Whether a
// stack then writes ready chunks together is its own business (hyper
// does; Go flushes each).

// streamEventsMax bounds the events a checked stream may have.
const streamEventsMax = 64

// checkStream checks a raw HTTP/1.1 response (curl --include --raw)
// against the reference stream: "" when it is right.
func checkStream(raw string, reference string) string {
	head, body, found := strings.Cut(raw, "\r\n\r\n")
	if !found {
		return "no end of the response head"
	}
	lines := strings.Split(head, "\r\n")
	if !strings.HasPrefix(lines[0], "HTTP/1.1 200 ") {
		return fmt.Sprintf("status line %q, not 200", lines[0])
	}
	contentType, chunked, length := "", false, false
	for _, line := range lines[1:] {
		name, value, _ := strings.Cut(line, ":")
		value = strings.TrimSpace(value)
		switch strings.ToLower(name) {
		case "content-type":
			contentType = value
		case "transfer-encoding":
			chunked = strings.EqualFold(value, "chunked")
		case "content-length":
			length = true
		}
	}
	if !strings.HasPrefix(contentType, "text/event-stream") {
		return fmt.Sprintf("Content-Type %q, not text/event-stream", contentType)
	}
	if !chunked || length {
		return "not streamed: the contract is chunked, with no Content-Length"
	}
	chunks, err := readChunks(body)
	if err != nil {
		return "chunked body: " + err.Error()
	}
	events := splitEvents(reference)
	if len(chunks) != len(events) {
		return fmt.Sprintf("%d chunks for %d events: the contract is one chunk per event",
			len(chunks), len(events))
	}
	for i := range events {
		if chunks[i] != events[i] {
			return fmt.Sprintf("event %d is %q, not %q", i+1, chunks[i], events[i])
		}
	}
	return ""
}

// readChunks decodes a chunked body into its chunks, the last (empty) one
// left out; trailers are refused, as the contract has none.
func readChunks(body string) ([]string, error) {
	reader := bufio.NewReader(strings.NewReader(body))
	var chunks []string
	for range streamEventsMax + 1 {
		line, err := reader.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("chunk size: %w", err)
		}
		size, err := strconv.ParseUint(strings.TrimSuffix(line, "\r\n"), 16, 32)
		if err != nil || !strings.HasSuffix(line, "\r\n") {
			return nil, fmt.Errorf("chunk size line %q", line)
		}
		if size == 0 {
			if end, _ := reader.ReadString('\n'); end != "\r\n" {
				return nil, fmt.Errorf("trailer or junk after the last chunk: %q", end)
			}
			if rest, _ := io.ReadAll(reader); len(rest) != 0 {
				return nil, fmt.Errorf("%d bytes after the body", len(rest))
			}
			return chunks, nil
		}
		data := make([]byte, size+2)
		if _, err := io.ReadFull(reader, data); err != nil {
			return nil, fmt.Errorf("chunk data: %w", err)
		}
		if string(data[size:]) != "\r\n" {
			return nil, fmt.Errorf("chunk of %d bytes not followed by CRLF", size)
		}
		chunks = append(chunks, string(data[:size]))
	}
	return nil, fmt.Errorf("more than %d chunks", streamEventsMax)
}

// splitEvents splits a stream into its events, each with its blank line.
func splitEvents(stream string) []string {
	var events []string
	for rest := stream; rest != ""; {
		event, after, found := strings.Cut(rest, "\n\n")
		if !found {
			return append(events, rest)
		}
		events = append(events, event+"\n\n")
		rest = after
	}
	return events
}
