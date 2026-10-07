package main

import (
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAPI answers every DigitalOcean call with 204 and records them: the
// fleet's deletions, checked without the network or an account.
type fakeAPI struct {
	mutex sync.Mutex
	calls []string
}

func (api *fakeAPI) RoundTrip(request *http.Request) (*http.Response, error) {
	api.mutex.Lock()
	api.calls = append(api.calls, request.Method+" "+request.URL.Path)
	api.mutex.Unlock()
	return &http.Response{StatusCode: http.StatusNoContent, Body: io.NopCloser(strings.NewReader("")),
		Header: http.Header{}, Request: request}, nil
}

func testFleet() *Fleet {
	start := time.Now().Add(-10 * time.Minute)
	fleet := &Fleet{loaders: map[string]Droplet{"a": {ID: 1}, "b": {ID: 3}},
		servers: map[string]Droplet{"a": {ID: 2}, "b": {ID: 4}}, created: []int{1, 2, 3, 4},
		lives: map[int]*dropletLife{}, key: SSHKey{ID: 9}}
	for id, role := range map[int]string{1: "loader", 2: "server", 3: "loader", 4: "server"} {
		class := "a"
		if id > 2 {
			class = "b"
		}
		fleet.lives[id] = &dropletLife{role: role, class: class, size: role + "-size", created: start}
	}
	return fleet
}

// A class done releases its own pair, once; the race's end deletes the
// rest and the key, once, however often it is called.
func TestFleetReleasesEachClassOnce(t *testing.T) {
	api := &fakeAPI{}
	do := &DigitalOcean{client: &http.Client{Transport: api}}
	fleet := testFleet()
	fleet.releaseClass(do, "a")
	fleet.releaseClass(do, "a")
	if got := strings.Join(api.calls, ","); got != "DELETE /v2/droplets/1,DELETE /v2/droplets/2" {
		t.Fatalf("after class a: %s", got)
	}
	fleet.destroy(do)
	fleet.destroy(do)
	want := "DELETE /v2/droplets/1,DELETE /v2/droplets/2,DELETE /v2/droplets/3," +
		"DELETE /v2/droplets/4,DELETE /v2/account/keys/9"
	if got := strings.Join(api.calls, ","); got != want {
		t.Fatalf("after the race:\n got %s\nwant %s", got, want)
	}
	for id, life := range fleet.lives {
		if life.deleted.IsZero() {
			t.Fatalf("droplet %d has no deletion time", id)
		}
	}
}

func TestFleetCosts(t *testing.T) {
	fleet := testFleet()
	fleet.lives[1].deleted = fleet.lives[1].created.Add(30 * time.Minute)
	fleet.lives[2].deleted = fleet.lives[2].created.Add(20 * time.Second)
	prices := map[string]float64{"loader-size": 0.12, "server-size": 0.06}
	costs := fleet.costs(prices)
	if len(costs) != 4 || costs[0].Role != "loader" || costs[0].Class != "a" {
		t.Fatalf("costs: %+v", costs)
	}
	if costs[0].Seconds != 1800 || math.Abs(costs[0].CostUSD-0.06) > 1e-12 {
		t.Fatalf("half an hour at $0.12: %+v", costs[0])
	}
	// Under a minute is billed as a minute.
	if math.Abs(costs[1].CostUSD-0.001) > 1e-12 {
		t.Fatalf("twenty seconds: %+v", costs[1])
	}
	// Not deleted yet: counted until now, about ten minutes.
	if costs[2].Seconds < 599 || costs[2].Seconds > 700 {
		t.Fatalf("still running: %+v", costs[2])
	}
}

// Measured 2026-10-06: a 26 s snapshot window around 20 s of load read a
// saturated CPU as 78% busy. Over the load's own duration it is all of it.
func TestCostOverTheLoad(t *testing.T) {
	cost := ServerCost{Seconds: 26, CPU: CPUShares{Busy: 78, User: 40, Softirq: 30},
		NetRxMbps: 1000}
	scaled := cost.over(20)
	if scaled.CPU.Busy != 100 || math.Abs(scaled.CPU.User-52) > 1e-9 || math.Abs(scaled.NetRxMbps-1300) > 1e-9 {
		t.Fatalf("over 20 s: %+v", scaled)
	}
	if cost.over(0) != cost || cost.over(30) != cost {
		t.Fatal("no load duration, or one longer than the window: unchanged")
	}
}

func TestCorrectWindowOnce(t *testing.T) {
	round := Round{Seconds: 26, CPUBusyPct: 78, LoaderCPUBusyPct: 50, NetRxMbps: 1000}
	round.correctWindow(20)
	if round.CPUBusyPct != 100 || math.Abs(round.LoaderCPUBusyPct-65) > 1e-9 ||
		math.Abs(round.NetRxMbps-1300) > 1e-9 || round.LoadSeconds != 20 {
		t.Fatalf("corrected: %+v", round)
	}
	round.correctWindow(20)
	if math.Abs(round.LoaderCPUBusyPct-65) > 1e-9 {
		t.Fatal("corrected twice")
	}
	old := Round{CPUBusyPct: 90}
	old.correctWindow(20)
	if old.CPUBusyPct != 90 || old.LoadSeconds != 0 {
		t.Fatal("a round with no window is left alone")
	}
}
