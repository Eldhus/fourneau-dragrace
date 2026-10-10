package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net"
	"reflect"
	"strings"
	"sync"
)

// A mixed workload (conduit: RACING.md, "The contract") is reads and writes
// at once against a database, open loop only: a ladder of fixed total
// rates, the same for every competitor, each offered as its parts at their
// shares, one oha a part, all at once. A competitor climbs until it falls
// behind (answers under `saturated` of the rate offered, or errors), and
// each step records the mean latency over every request (the chart), and
// each part's own numbers.

// Mixed is a workload's mixed load (race.json).
type Mixed struct {
	// Offered requests a second, in all, step by step.
	Rates          []int   `json:"rates"`
	WarmupSeconds  int     `json:"warmup_seconds"`
	MeasureSeconds int     `json:"measure_seconds"`
	Saturated      float64 `json:"saturated"`
	Parts          []Part  `json:"parts"`
}

// Part is one kind of request in the mix. Its path is a rand_regex
// (oha --rand-regex-url): each request a random article or page.
type Part struct {
	Name   string  `json:"name"`
	Method string  `json:"method"`
	Path   string  `json:"path"`
	Share  float64 `json:"share"`
	// Auth: the load user's token (Authorization: Token ...).
	Auth bool   `json:"auth"`
	Body string `json:"body"`
}

// OpenPart is one part of a mixed step, measured.
type OpenPart struct {
	Name        string  `json:"name"`
	OfferedRPS  float64 `json:"offered_rps"`
	AchievedRPS float64 `json:"achieved_rps"`
	MeanMs      float64 `json:"mean_ms"`
	P50Ms       float64 `json:"p50_ms"`
	P99Ms       float64 `json:"p99_ms"`
	P999Ms      float64 `json:"p999_ms"`
	Errors      int     `json:"errors"`
	Non2xx      int     `json:"non_2xx"`
}

// conduitSeedName is the seeded database on the server; each start copies
// it to conduitDatabaseName, so every competitor and every check starts
// from the same rows.
const (
	conduitSeedName     = "conduit-seed.db"
	conduitDatabaseName = "conduit.db"
)

// putConduitSeed puts the seeded database on the server, if the race has
// a mixed workload.
func putConduitSeed(ctx context.Context, root string, race Race, target Target) error {
	if !race.hasMixed() {
		return nil
	}
	return target.Server.Put(ctx, conduitDatabase(root), target.ServerHome+"/"+conduitSeedName)
}

// mixedLoop climbs every mixed workload's ladder for every valid
// competitor, after the rounds and the open loop.
func mixedLoop(ctx context.Context, race Race, competitors []Competitor, target Target,
	valid map[string]string, run *Run) error {
	for _, workload := range race.Workloads {
		if workload.Mixed == nil {
			continue
		}
		for _, competitor := range shuffled(competitors, run.Seed+int64(race.Rounds)+2) {
			if !competitor.offers(workload) {
				continue
			}
			result := resultFor(run, target.Class.Name, workload.Name, competitor.Name)
			why := valid[validKey(competitor.Name, workload.mode())]
			result.Valid, result.Note = why == "", why
			if result.Valid {
				log.Printf("[%s] %s: %s", target.Class.Name, workload.Name, competitor.Name)
				steps, why, err := climbMixed(ctx, race, workload, competitor, target)
				if err != nil {
					return fmt.Errorf("%s %s: %w", competitor.Name, workload.Name, err)
				}
				result.Valid, result.Note, result.OpenLoop = why == "", why, steps
			}
			target.report(*result)
		}
	}
	return nil
}

// freshDatabase is the server's script to start from the seed again: a
// race with a mixed workload starts every server (each round too) on a
// fresh copy of the seeded database, `{db}` in its arguments.
func freshDatabase(target Target) string {
	return fmt.Sprintf("cd %s && rm -f %s %[2]s-wal %[2]s-shm && cp %s %[2]s",
		quote(target.ServerHome), conduitDatabaseName, conduitSeedName)
}

// climbMixed checks the competitor against the contract, then climbs; a
// competitor that fails the checks has no steps and says why.
func climbMixed(ctx context.Context, race Race, workload Workload, competitor Competitor,
	target Target) ([]OpenStep, string, error) {
	mode := workload.mode()
	pid, err := startServer(ctx, race, competitor, target, mode)
	if err != nil {
		return nil, "", err
	}
	if err := waitReady(ctx, race, target, mode); err != nil {
		why := "did not start: " + whyNotReady(ctx, competitor, target, pid)
		stopServer(context.WithoutCancel(ctx), target, pid)
		return nil, why, nil
	}
	why := validateConduit(ctx, race, target, mode)
	stopServer(context.WithoutCancel(ctx), target, pid)
	if why != "" {
		return nil, why, nil
	}
	// The checks wrote: the climb starts from the seed again.
	pid, err = startServer(ctx, race, competitor, target, mode)
	if err != nil {
		return nil, "", err
	}
	defer stopServer(context.WithoutCancel(ctx), target, pid)
	if err := waitReady(ctx, race, target, mode); err != nil {
		return nil, "did not start again: " + whyNotReady(ctx, competitor, target, pid), nil
	}
	mixed := workload.Mixed
	local := net.ParseIP(target.Address).IsLoopback()
	steps := []OpenStep{}
	for _, rate := range mixed.Rates {
		if _, err := runParts(ctx, race, workload, target, rate, mixed.WarmupSeconds); err != nil {
			return nil, "", fmt.Errorf("warmup at %d/s: %w", rate, err)
		}
		serverBefore, loaderBefore, err := snapshots(ctx, target, pid, true)
		if err != nil {
			return nil, "", err
		}
		parts, err := runParts(ctx, race, workload, target, rate, mixed.MeasureSeconds)
		if err != nil {
			return nil, "", fmt.Errorf("at %d/s: %w", rate, err)
		}
		serverAfter, loaderAfter, err := snapshots(ctx, target, pid, false)
		if err != nil {
			return nil, "", err
		}
		step := mixedStep(rate, parts)
		seconds := float64(mixed.MeasureSeconds)
		cost := serverCost(serverBefore, serverAfter, target.ServerCPUs, local).over(seconds)
		step.CPUBusyPct, step.NetRxMbps, step.NetTxMbps = cost.CPU.Busy, cost.NetRxMbps, cost.NetTxMbps
		step.LoaderCPUBusyPct = loaderBusy(loaderBefore, loaderAfter, target.LoaderCPUs, seconds)
		log.Printf("    %8d/s offered  %8.0f/s good  mean %.2f ms  worst p99 %.2f ms",
			rate, step.AchievedRPS, step.MeanMs, step.P99Ms)
		steps = append(steps, step)
		if step.AchievedRPS < mixed.Saturated*float64(rate) || step.Errors > 0 {
			break // behind: the next rate would only be further behind
		}
	}
	return steps, "", nil
}

// mixedStep sums the parts: the rates add, the mean is over every request
// (each part's mean weighted by its answers); a step's percentiles are the
// worst part's, as a percentile of the whole cannot be had from the parts.
func mixedStep(rate int, parts []OpenPart) OpenStep {
	step := OpenStep{Share: 0, OfferedRPS: float64(rate), Parts: parts}
	weighted := 0.0
	for _, part := range parts {
		step.AchievedRPS += part.AchievedRPS
		weighted += part.MeanMs * part.AchievedRPS
		step.P50Ms = math.Max(step.P50Ms, part.P50Ms)
		step.P99Ms = math.Max(step.P99Ms, part.P99Ms)
		step.P999Ms = math.Max(step.P999Ms, part.P999Ms)
		step.Errors += part.Errors
		step.Non2xx += part.Non2xx
	}
	if step.AchievedRPS > 0 {
		step.MeanMs = weighted / step.AchievedRPS
	}
	return step
}

// runParts runs every part's oha at once, each at its share of the rate.
func runParts(ctx context.Context, race Race, workload Workload, target Target, rate,
	seconds int) ([]OpenPart, error) {
	parts := workload.Mixed.Parts
	measured := make([]OpenPart, len(parts))
	errs := make([]error, len(parts))
	var wait sync.WaitGroup
	for i, part := range parts {
		wait.Add(1)
		go func() {
			defer wait.Done()
			offered := max(1, int(math.Round(part.Share*float64(rate))))
			report, err := target.Loader.Shell(ctx, partCommand(race, workload, target, part,
				offered, seconds))
			if err != nil {
				errs[i] = fmt.Errorf("%s: %w", part.Name, err)
				return
			}
			round, err := parseOha(report)
			if err != nil {
				errs[i] = fmt.Errorf("%s: %w", part.Name, err)
				return
			}
			measured[i] = OpenPart{Name: part.Name, OfferedRPS: float64(offered),
				AchievedRPS: round.RPS, MeanMs: round.MeanMs, P50Ms: round.P50Ms,
				P99Ms: round.P99Ms, P999Ms: round.P999Ms, Errors: round.Errors, Non2xx: round.Non2xx}
		}()
	}
	wait.Wait()
	for _, err := range errs {
		if err != nil {
			return nil, err
		}
	}
	return measured, nil
}

// partCommand is one part's oha: open loop at its rate, its connections
// and threads its share of the workload's.
func partCommand(race Race, workload Workload, target Target, part Part, rate,
	seconds int) string {
	connections := max(8, int(math.Ceil(part.Share*float64(workload.Connections))))
	var command strings.Builder
	command.WriteString("ulimit -n $(ulimit -Hn); " + target.taskset(target.LoaderCPUs))
	fmt.Fprintf(&command, "%s/oha -z %ds -c %d -q %d --latency-correction --no-tui "+
		"--output-format json --disable-compression --rand-regex-url",
		quote(target.LoaderHome), seconds, connections, rate)
	if target.LoaderThreads > 0 {
		threads := max(1, int(math.Ceil(part.Share*float64(target.LoaderThreads))))
		fmt.Fprintf(&command, " --worker-threads %d", threads)
	}
	if part.Method != "GET" {
		command.WriteString(" -m " + part.Method)
	}
	if part.Auth {
		command.WriteString(" -H " + quote("Authorization: Token "+conduitToken(conduitLoadUser)))
	}
	if part.Body != "" {
		command.WriteString(" -d " + quote(part.Body) + " -T application/json")
	}
	if workload.HTTP2 {
		fmt.Fprintf(&command, " --http2 -p %d", max(1, workload.Streams))
	}
	if workload.TLS {
		command.WriteString(" --insecure") // the race's own certificate
	}
	// rand_regex: the base URL's dots are written as [.], so only the path varies.
	base := strings.ReplaceAll(baseURL(race, target, workload.mode()), ".", "[.]")
	command.WriteString(" " + quote(base+part.Path))
	return command.String()
}

// validateConduit checks a competitor against the contract, from the
// loader, on the seeded database: "" when it answers as the model says.
func validateConduit(ctx context.Context, race Race, target Target, mode Mode) string {
	model := newConduitModel()
	url := baseURL(race, target, mode)
	token := conduitToken(conduitLoadUser)
	curl := strings.Replace(curlFor(mode), "-m 5", "-m 10", 1)
	type check struct {
		name, curl string
		status     string
		want       func(map[string]any) string
	}
	same := func(want any) func(map[string]any) string {
		return func(got map[string]any) string {
			if reflect.DeepEqual(got, want) {
				return ""
			}
			return describeDifference(got, want)
		}
	}
	free := model.unfavorited()
	favorite := model.article(free, true)
	favorite["favorited"] = true
	favorite["favoritesCount"] = float64(len(model.articles[free].Favorites) + 1)
	checks := []check{
		{"the list", curl + "-w '\\n%{http_code} %{content_type}' '" + url +
			"/api/articles?limit=20&offset=40'", "200", same(model.list(20, 40))},
		{"an article", curl + "-w '\\n%{http_code} %{content_type}' " + url +
			"/api/articles/article-0123", "200", same(map[string]any{"article": model.article(123, true)})},
		{"a missing article", curl + "-o /dev/null -w '\\n%{http_code} -' " + url +
			"/api/articles/article-9999", "404", nil},
		{"a comment without a token", curl + "-o /dev/null -w '\\n%{http_code} -' -X POST " +
			"-H 'Content-Type: application/json' -d '{\"comment\":{\"body\":\"x\"}}' " + url +
			"/api/articles/article-0001/comments", "401", nil},
		{"a comment", curl + "-w '\\n%{http_code} %{content_type}' -X POST " +
			"-H 'Authorization: Token " + token + "' -H 'Content-Type: application/json' " +
			"-d '{\"comment\":{\"body\":\"Lovely roux.\"}}' " + url + "/api/articles/article-0001/comments",
			"200", func(got map[string]any) string {
				comment, _ := got["comment"].(map[string]any)
				if comment == nil {
					return "no comment in the answer"
				}
				id, isNumber := comment["id"].(float64)
				created, _ := comment["createdAt"].(string)
				if !isNumber || id <= float64(len(model.comments)) || len(created) != 24 {
					return fmt.Sprintf("id %v and createdAt %v: a new id, and ISO 8601 with ms", comment["id"], comment["createdAt"])
				}
				want := map[string]any{"id": comment["id"], "createdAt": created,
					"updatedAt": comment["updatedAt"], "body": "Lovely roux.",
					"author": model.author(conduitLoadUser)}
				return same(map[string]any{"comment": want})(got)
			}},
		{"a favorite", curl + "-w '\\n%{http_code} %{content_type}' -X POST " +
			"-H 'Authorization: Token " + token + "' " + url + "/api/articles/" +
			model.articles[free].Slug + "/favorite", "200", same(map[string]any{"article": favorite})},
	}
	for _, check := range checks {
		output, err := target.Loader.Shell(ctx, check.curl)
		if err != nil {
			return fmt.Sprintf("%s: %v", check.name, err)
		}
		lineBreak := strings.LastIndex(output, "\n")
		body, tail := output[:max(lineBreak, 0)], output[lineBreak+1:]
		status, contentType, _ := strings.Cut(tail, " ")
		if status != check.status {
			return fmt.Sprintf("%s: %s, not %s", check.name, status, check.status)
		}
		if check.want == nil {
			continue
		}
		if !strings.HasPrefix(contentType, "application/json") {
			return fmt.Sprintf("%s: Content-Type %q, not application/json", check.name, contentType)
		}
		var got map[string]any
		if err := json.Unmarshal([]byte(body), &got); err != nil {
			return fmt.Sprintf("%s: not JSON: %.80s", check.name, body)
		}
		if why := check.want(got); why != "" {
			return check.name + ": " + why
		}
	}
	return ""
}

// describeDifference names the first place two JSON values differ.
func describeDifference(got, want any) string {
	var walk func(path string, got, want any) string
	walk = func(path string, got, want any) string {
		switch want := want.(type) {
		case map[string]any:
			object, isObject := got.(map[string]any)
			if !isObject {
				return fmt.Sprintf("%s: %v, not an object", path, got)
			}
			for key, value := range want {
				if why := walk(path+"."+key, object[key], value); why != "" {
					return why
				}
			}
			for key := range object {
				if _, wanted := want[key]; !wanted {
					return fmt.Sprintf("%s.%s: not in the contract", path, key)
				}
			}
		case []any:
			list, isList := got.([]any)
			if !isList || len(list) != len(want) {
				return fmt.Sprintf("%s: %v, want %d items", path, got, len(want))
			}
			for i := range want {
				if why := walk(fmt.Sprintf("%s[%d]", path, i), list[i], want[i]); why != "" {
					return why
				}
			}
		default:
			if !reflect.DeepEqual(got, want) {
				return fmt.Sprintf("%s: %v, want %v", path, got, want)
			}
		}
		return ""
	}
	return walk("", got, want)
}
