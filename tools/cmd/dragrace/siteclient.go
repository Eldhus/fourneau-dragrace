package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// SiteClient speaks to the site's API (docs/self-hosting.md) with a bearer
// token. A post the site did not answer, or answered 5xx (a deploy
// restarting it, a database busy), is sent again with backoff, 1 s
// doubling to 30 s, for 20 minutes: ten times what a deploy takes. The
// site answers a repeat as the first, so a post whose answer was lost
// does no harm sent twice. A 4xx is the site refusing: never retried.
type SiteClient struct {
	base   string
	token  string
	client *http.Client
	window time.Duration
	first  time.Duration
	most   time.Duration
	sleep  func(ctx context.Context, wait time.Duration) error
}

const siteRetryWindow = 20 * time.Minute

func newSiteClient(base, token string) *SiteClient {
	return &SiteClient{base: strings.TrimSuffix(base, "/"), token: token,
		client: &http.Client{Timeout: time.Minute}, window: siteRetryWindow,
		first: time.Second, most: 30 * time.Second, sleep: sleepContext}
}

func sleepContext(ctx context.Context, wait time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(wait):
		return nil
	}
}

// errSiteRefused is a 4xx: the site will not take it, however often sent.
var errSiteRefused = errors.New("the site refused")

// call sends one request, retrying as the type says, and decodes a JSON
// answer into `into` (nil: ignored).
func (site *SiteClient) call(ctx context.Context, method, path string, body, into any) error {
	var encoded []byte
	if body != nil {
		var err error
		if encoded, err = json.Marshal(body); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(site.window)
	wait := site.first
	for attempt := 1; ; attempt++ {
		answer, err := site.once(ctx, method, path, encoded)
		if err == nil {
			if into == nil {
				return nil
			}
			return json.Unmarshal(answer, into)
		}
		if errors.Is(err, errSiteRefused) || ctx.Err() != nil {
			return err
		}
		if time.Now().Add(wait).After(deadline) {
			return fmt.Errorf("%s %s: %d attempts over %s: %w", method, path, attempt, site.window, err)
		}
		log.Printf("site %s %s (attempt %d): %v; again in %s", method, path, attempt, err, wait)
		if err := site.sleep(ctx, wait); err != nil {
			return err
		}
		wait = min(2*wait, site.most)
	}
}

func (site *SiteClient) once(ctx context.Context, method, path string, body []byte) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, site.base+path, reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+site.token)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := site.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	answer, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	switch {
	case response.StatusCode/100 == 2:
		return answer, nil
	case response.StatusCode/100 == 4 && response.StatusCode != http.StatusTooManyRequests:
		return nil, fmt.Errorf("%w: %s %s: %d: %s", errSiteRefused, method, path,
			response.StatusCode, strings.TrimSpace(string(answer)))
	}
	return nil, fmt.Errorf("%d: %s", response.StatusCode, strings.TrimSpace(string(answer)))
}

func (site *SiteClient) post(ctx context.Context, path string, body, into any) error {
	return site.call(ctx, http.MethodPost, path, body, into)
}

func (site *SiteClient) get(ctx context.Context, path string, into any) error {
	return site.call(ctx, http.MethodGet, path, nil, into)
}
