package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeDigitalOcean is a Provider in memory: what the guard is tested on.
type fakeDigitalOcean struct {
	mutex    sync.Mutex
	next     int
	droplets map[int]Droplet
	keyList  []SSHKey
	prices   map[string]float64
}

func newFakeDigitalOcean() *fakeDigitalOcean {
	return &fakeDigitalOcean{next: 100, droplets: map[int]Droplet{},
		prices: map[string]float64{"c-2": 0.0625, "c-4": 0.125, "s-1vcpu-512mb-10gb": 0.00595,
			"c-32": 1.0}}
}

func (fake *fakeDigitalOcean) createDroplet(_ context.Context, request DropletRequest) (Droplet, error) {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	fake.next++
	droplet := Droplet{ID: fake.next, Name: request.Name, Status: "active", Tags: request.Tags,
		SizeSlug: request.Size}
	type address = struct {
		IPAddress string `json:"ip_address"`
		Type      string `json:"type"`
	}
	droplet.Networks.V4 = []address{{IPAddress: "203.0.113.1", Type: "public"},
		{IPAddress: "10.0.0.1", Type: "private"}}
	fake.droplets[droplet.ID] = droplet
	return droplet, nil
}

func (fake *fakeDigitalOcean) droplet(_ context.Context, id int) (Droplet, error) {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	droplet, found := fake.droplets[id]
	if !found {
		return droplet, fmt.Errorf("DigitalOcean: 404 not found")
	}
	return droplet, nil
}

func (fake *fakeDigitalOcean) dropletsTagged(_ context.Context, tag string) ([]Droplet, error) {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	var tagged []Droplet
	for _, droplet := range fake.droplets {
		if contains(droplet.Tags, tag) {
			tagged = append(tagged, droplet)
		}
	}
	return tagged, nil
}

func (fake *fakeDigitalOcean) deleteDroplet(_ context.Context, id int) error {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	if _, found := fake.droplets[id]; !found {
		return fmt.Errorf("DigitalOcean: 404 not found")
	}
	delete(fake.droplets, id)
	return nil
}

func (fake *fakeDigitalOcean) createKey(_ context.Context, name, public string) (SSHKey, error) {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	fake.next++
	key := SSHKey{ID: fake.next, Name: name, PublicKey: public}
	fake.keyList = append(fake.keyList, key)
	return key, nil
}

func (fake *fakeDigitalOcean) keys(context.Context) ([]SSHKey, error) {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	return append([]SSHKey(nil), fake.keyList...), nil
}

func (fake *fakeDigitalOcean) deleteKey(_ context.Context, id int) error {
	fake.mutex.Lock()
	defer fake.mutex.Unlock()
	for i, key := range fake.keyList {
		if key.ID == id {
			fake.keyList = append(fake.keyList[:i], fake.keyList[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("DigitalOcean: 404 not found")
}

func (fake *fakeDigitalOcean) sizes(context.Context) ([]Size, error) {
	var sizes []Size
	for slug, price := range fake.prices {
		sizes = append(sizes, Size{Slug: slug, Available: true, PriceHourly: price})
	}
	return sizes, nil
}

func testGuard(t *testing.T, capUSD float64) (*Guard, *fakeDigitalOcean, *time.Time) {
	t.Helper()
	now := time.Date(2026, 10, 7, 7, 0, 0, 0, time.UTC)
	fake := newFakeDigitalOcean()
	guard := &Guard{provider: fake, now: func() time.Time { return now }, config: GuardConfig{
		Region: "lon1", Image: "ubuntu-26-04-x64", Tag: "fourneau-dragrace-race",
		Sizes:         map[string]float64{"c-2": 0.07, "c-4": 0.13, "s-1vcpu-512mb-10gb": 0.01},
		MonthlyCapUSD: capUSD, DropletsMax: 4, AgeMaxMinutes: 180,
		Socket: filepath.Join(t.TempDir(), "guard.sock"), Ledger: filepath.Join(t.TempDir(), "ledger.json"),
	}}
	if err := guard.config.check(); err != nil {
		t.Fatal(err)
	}
	return guard, fake, &now
}

func raceDroplet(size string) DropletRequest {
	return DropletRequest{Name: "dragrace-server-x", Region: "lon1", Size: size,
		Image: "ubuntu-26-04-x64", Tags: []string{"fourneau-dragrace-race"}}
}

func TestGuardRefusesWhatTheOwnerDidNotAllow(t *testing.T) {
	guard, fake, _ := testGuard(t, 25)
	fake.prices["c-2"] = 0.09 // DigitalOcean raised the price past the allowed
	cases := map[string]DropletRequest{
		"size not allowed": raceDroplet("c-32"),
		"price above":      raceDroplet("c-2"),
		"region":           func() DropletRequest { r := raceDroplet("c-4"); r.Region = "nyc3"; return r }(),
		"image":            func() DropletRequest { r := raceDroplet("c-4"); r.Image = "debian"; return r }(),
		"tag":              func() DropletRequest { r := raceDroplet("c-4"); r.Tags = nil; return r }(),
		"name":             func() DropletRequest { r := raceDroplet("c-4"); r.Name = "miner"; return r }(),
	}
	for name, request := range cases {
		if _, err := guard.createDroplet(context.Background(), request); !errors.Is(err, errRefused) {
			t.Errorf("%s: %v, want a refusal", name, err)
		}
	}
	if len(fake.droplets) != 0 {
		t.Fatalf("droplets made: %v", fake.droplets)
	}
	if _, err := guard.createDroplet(context.Background(), raceDroplet("c-4")); err != nil {
		t.Fatalf("an allowed droplet: %v", err)
	}
}

func TestGuardKeepsTheMonthUnderItsCap(t *testing.T) {
	// c-4 at $0.125 an hour, for at most 3 hours: $0.375 committed each.
	guard, _, now := testGuard(t, 1.0)
	ctx := context.Background()
	for i := range 2 {
		if _, err := guard.createDroplet(ctx, raceDroplet("c-4")); err != nil {
			t.Fatalf("droplet %d: %v", i, err)
		}
	}
	_, err := guard.createDroplet(ctx, raceDroplet("c-4"))
	if !errors.Is(err, errRefused) || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("a third: %v, want the budget's refusal", err)
	}
	// An hour later both are deleted: $0.25 spent, nothing committed.
	*now = now.Add(time.Hour)
	for _, life := range append([]Life(nil), guard.lives...) {
		if err := guard.deleteDroplet(ctx, life.ID); err != nil {
			t.Fatal(err)
		}
	}
	if spent := guard.monthSpent(*now); spent < 0.2499 || spent > 0.2501 {
		t.Fatalf("spent %.4f, want 0.25", spent)
	}
	if _, err := guard.createDroplet(ctx, raceDroplet("c-4")); err != nil {
		t.Fatalf("after: %v", err)
	}
	// A new month starts from what is still alive only.
	*now = time.Date(2026, 11, 1, 0, 30, 0, 0, time.UTC)
	if spent := guard.monthSpent(*now); spent > 0.0626 {
		t.Fatalf("November spent %.4f, want at most half an hour of one c-4", spent)
	}
}

func TestGuardDropletsMaxAndLedgerSurvivesARestart(t *testing.T) {
	guard, fake, now := testGuard(t, 25)
	ctx := context.Background()
	for range 4 {
		if _, err := guard.createDroplet(ctx, raceDroplet("s-1vcpu-512mb-10gb")); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := guard.createDroplet(ctx, raceDroplet("s-1vcpu-512mb-10gb")); !errors.Is(err, errRefused) {
		t.Fatalf("a fifth: %v", err)
	}
	again := &Guard{config: guard.config, provider: fake, now: func() time.Time { return *now }}
	if err := again.load(); err != nil {
		t.Fatal(err)
	}
	if len(again.lives) != 4 {
		t.Fatalf("ledger read back %d lives", len(again.lives))
	}
}

func TestGuardReapsOldDropletsAndForgetsVanishedOnes(t *testing.T) {
	guard, fake, now := testGuard(t, 25)
	ctx := context.Background()
	old, _ := guard.createDroplet(ctx, raceDroplet("c-2"))
	*now = now.Add(2 * time.Hour)
	young, _ := guard.createDroplet(ctx, raceDroplet("c-2"))
	gone, _ := guard.createDroplet(ctx, raceDroplet("c-2"))
	delete(fake.droplets, gone.ID) // deleted behind the guard's back
	*now = now.Add(90 * time.Minute)
	guard.reap(ctx)
	if _, found := fake.droplets[old.ID]; found {
		t.Fatal("a droplet past its age still lives")
	}
	if _, found := fake.droplets[young.ID]; !found {
		t.Fatal("a young droplet was deleted")
	}
	for _, life := range guard.lives {
		if life.ID != young.ID && life.alive() {
			t.Fatalf("droplet %d still counted alive", life.ID)
		}
	}
}

func TestLifeCostIsBilledPerSecondAtLeastAMinute(t *testing.T) {
	start := time.Date(2026, 10, 31, 23, 0, 0, 0, time.UTC)
	life := Life{PriceHourly: 1, Created: start, Deleted: start.Add(2 * time.Hour)}
	october := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	november := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	if cost := life.cost(october, november); cost != 1 {
		t.Fatalf("October %v, want 1", cost)
	}
	if cost := life.cost(november, november.AddDate(0, 1, 0)); cost != 1 {
		t.Fatalf("November %v, want 1", cost)
	}
	short := Life{PriceHourly: 3600, Created: start, Deleted: start.Add(time.Second)}
	if cost := short.cost(october, november); cost != 60 {
		t.Fatalf("a second's droplet %v, want a minute's 60", cost)
	}
}

func TestGuardOverItsSocket(t *testing.T) {
	guard, fake, _ := testGuard(t, 25)
	socket := filepath.Join(t.TempDir(), "g.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: guard.handler()}
	go server.Serve(listener)
	defer server.Close()
	client := newGuardClient(socket)
	ctx := context.Background()
	if _, err := client.createDroplet(ctx, raceDroplet("c-32")); !errors.Is(err, errRefused) {
		t.Fatalf("refusal over the socket: %v", err)
	}
	made, err := client.createDroplet(ctx, raceDroplet("c-2"))
	if err != nil {
		t.Fatal(err)
	}
	if droplet, err := waitActive(ctx, client, made.ID); err != nil || droplet.ID != made.ID {
		t.Fatalf("waitActive: %v %v", droplet, err)
	}
	// A droplet the guard did not make, untagged: neither read nor deleted.
	fake.droplets[7] = Droplet{ID: 7, Name: "the site", Status: "active"}
	if _, err := client.droplet(ctx, 7); !errors.Is(err, errRefused) {
		t.Fatalf("reading another droplet: %v", err)
	}
	if err := client.deleteDroplet(ctx, 7); !errors.Is(err, errRefused) {
		t.Fatalf("deleting another droplet: %v", err)
	}
	if _, err := client.createKey(ctx, "owner-laptop", "ssh-ed25519 AAAA"); !errors.Is(err, errRefused) {
		t.Fatalf("a key not the race's: %v", err)
	}
	key, err := client.createKey(ctx, sshKeyPrefix+"1", "ssh-ed25519 AAAA")
	if err != nil {
		t.Fatal(err)
	}
	if err := client.deleteKey(ctx, key.ID); err != nil {
		t.Fatal(err)
	}
	if err := client.deleteDroplet(ctx, made.ID); err != nil {
		t.Fatal(err)
	}
	if len(fake.droplets) != 1 {
		t.Fatalf("left: %v", fake.droplets)
	}
}
