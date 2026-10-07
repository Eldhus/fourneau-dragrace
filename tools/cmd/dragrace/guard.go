package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The guard holds the DigitalOcean token on the racer, and nothing else
// does (docs/self-hosting.md, "The budget and the token"). The racer asks
// it over a Unix socket for the few things a race needs; it refuses a
// size, region or image the owner's config does not allow, more droplets
// alive than allowed, and any droplet that could take the month's spend
// past the cap. It deletes its droplets past their age, whatever the
// racer does. Installed by the owner, never updated by a build.

// GuardConfig is the owner's, on the racer's disk (/etc/dragrace-guard).
type GuardConfig struct {
	Region string `json:"region"`
	Image  string `json:"image"`
	Tag    string `json:"tag"`
	// The sizes allowed, each with the most it may cost an hour.
	Sizes         map[string]float64 `json:"sizes"`
	MonthlyCapUSD float64            `json:"monthly_cap_usd"`
	DropletsMax   int                `json:"droplets_max"`
	AgeMaxMinutes int                `json:"age_max_minutes"`
	Socket        string             `json:"socket"`
	Ledger        string             `json:"ledger"`
}

func (config GuardConfig) check() error {
	var problems []string
	if config.Region == "" || config.Image == "" || config.Tag == "" {
		problems = append(problems, "region, image and tag are required")
	}
	if len(config.Sizes) == 0 {
		problems = append(problems, "no sizes allowed")
	}
	if config.MonthlyCapUSD <= 0 || config.MonthlyCapUSD > guardCapUSDMax {
		problems = append(problems, fmt.Sprintf("monthly_cap_usd: above 0, at most %d", guardCapUSDMax))
	}
	if config.DropletsMax < 1 || config.DropletsMax > 16 {
		problems = append(problems, "droplets_max: 1 to 16")
	}
	if config.AgeMaxMinutes < 10 || config.AgeMaxMinutes > 24*60 {
		problems = append(problems, "age_max_minutes: 10 to 1440")
	}
	if config.Socket == "" || config.Ledger == "" {
		problems = append(problems, "socket and ledger are required")
	}
	if len(problems) > 0 {
		return fmt.Errorf("guard config: %s", strings.Join(problems, "; "))
	}
	return nil
}

// guardCapUSDMax bounds a cap typed with a zero too many.
const guardCapUSDMax = 200

// Life is one droplet the guard made, by its own clock, at the price it
// allowed.
type Life struct {
	ID          int       `json:"id"`
	Size        string    `json:"size"`
	PriceHourly float64   `json:"price_hourly"`
	Created     time.Time `json:"created"`
	Deleted     time.Time `json:"deleted"` // zero while alive
}

func (life Life) alive() bool { return life.Deleted.IsZero() }

// cost is what the life cost within [from, to): billed per second, at
// least a minute (dropletCost), its minute counted in the month it began.
func (life Life) cost(from, to time.Time) float64 {
	end := life.Deleted
	if end.IsZero() || end.After(to) {
		end = to
	}
	start := life.Created
	if start.Before(from) {
		start = from
	}
	if !end.After(start) {
		return 0
	}
	seconds := end.Sub(start).Seconds()
	if !life.Created.Before(from) && seconds < dropletBilledSecondsMin {
		seconds = dropletBilledSecondsMin
	}
	return life.PriceHourly * seconds / 3600
}

// Guard is the policy over a Provider, and the ledger.
type Guard struct {
	config   GuardConfig
	provider Provider
	now      func() time.Time
	mutex    sync.Mutex
	lives    []Life
}

// monthSpent is the month's spend so far, by the ledger.
func (guard *Guard) monthSpent(now time.Time) float64 {
	from := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	spent := 0.0
	for _, life := range guard.lives {
		spent += life.cost(from, now)
	}
	return spent
}

// committed is what the alive droplets may still cost: each until its age
// runs out (the guard deletes it then).
func (guard *Guard) committed(now time.Time) float64 {
	ageMax := time.Duration(guard.config.AgeMaxMinutes) * time.Minute
	total := 0.0
	for _, life := range guard.lives {
		if life.alive() {
			left := life.Created.Add(ageMax).Sub(now).Seconds()
			if left > 0 {
				total += life.PriceHourly * left / 3600
			}
		}
	}
	return total
}

// errRefused is the guard's refusal: the race asked for what the owner did
// not allow. The racer records the run as refused.
var errRefused = errors.New("refused by the guard")

// allow checks a droplet request against the config and the budget, with
// the size's price now; it returns the price to record.
func (guard *Guard) allow(request DropletRequest, priceNow float64) error {
	config := guard.config
	most, allowed := config.Sizes[request.Size]
	switch {
	case !allowed:
		return fmt.Errorf("%w: size %s is not allowed", errRefused, request.Size)
	case priceNow <= 0 || priceNow > most:
		return fmt.Errorf("%w: %s costs $%.4f an hour, the most allowed is $%.4f",
			errRefused, request.Size, priceNow, most)
	case request.Region != config.Region:
		return fmt.Errorf("%w: region %s, not %s", errRefused, request.Region, config.Region)
	case request.Image != config.Image:
		return fmt.Errorf("%w: image %s, not %s", errRefused, request.Image, config.Image)
	case len(request.Tags) != 1 || request.Tags[0] != config.Tag:
		return fmt.Errorf("%w: tags %v, not [%s]", errRefused, request.Tags, config.Tag)
	case !strings.HasPrefix(request.Name, "dragrace-"):
		return fmt.Errorf("%w: name %q", errRefused, request.Name)
	}
	now := guard.now()
	alive := 0
	for _, life := range guard.lives {
		if life.alive() {
			alive++
		}
	}
	if alive >= config.DropletsMax {
		return fmt.Errorf("%w: %d droplets alive, the most allowed", errRefused, alive)
	}
	ageMax := float64(config.AgeMaxMinutes) / 60
	spent, committed, next := guard.monthSpent(now), guard.committed(now), priceNow*ageMax
	if spent+committed+next > config.MonthlyCapUSD {
		return fmt.Errorf("%w: the month's budget: $%.2f spent, $%.2f committed, $%.2f more "+
			"would pass the cap of $%.2f", errRefused, spent, committed, next, config.MonthlyCapUSD)
	}
	return nil
}

func (guard *Guard) life(id int) (int, bool) {
	for i, life := range guard.lives {
		if life.ID == id {
			return i, true
		}
	}
	return 0, false
}

// load reads the ledger; none yet is an empty one.
func (guard *Guard) load() error {
	bytes, err := os.ReadFile(guard.config.Ledger)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(bytes, &guard.lives)
}

// save writes the ledger whole, atomically, dropping lives over 100 days
// old (no month's spend needs them).
func (guard *Guard) save() error {
	cutoff := guard.now().Add(-100 * 24 * time.Hour)
	kept := guard.lives[:0]
	for _, life := range guard.lives {
		if life.alive() || life.Deleted.After(cutoff) {
			kept = append(kept, life)
		}
	}
	guard.lives = kept
	bytes, err := json.MarshalIndent(guard.lives, "", "  ")
	if err != nil {
		return err
	}
	temporary := guard.config.Ledger + ".new"
	if err := os.WriteFile(temporary, bytes, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, guard.config.Ledger)
}

func (guard *Guard) createDroplet(ctx context.Context, request DropletRequest) (Droplet, error) {
	guard.mutex.Lock()
	defer guard.mutex.Unlock()
	sizes, err := guard.provider.sizes(ctx)
	if err != nil {
		return Droplet{}, err
	}
	price := 0.0
	for _, size := range sizes {
		if size.Slug == request.Size {
			price = size.PriceHourly
		}
	}
	if err := guard.allow(request, price); err != nil {
		return Droplet{}, err
	}
	request.Monitoring = false
	droplet, err := guard.provider.createDroplet(ctx, request)
	if err != nil {
		return droplet, err
	}
	guard.lives = append(guard.lives, Life{ID: droplet.ID, Size: request.Size,
		PriceHourly: price, Created: guard.now()})
	if err := guard.save(); err != nil {
		log.Printf("guard: the ledger: %v", err)
	}
	log.Printf("guard: droplet %d (%s, $%.4f/h); month $%.2f of $%.2f", droplet.ID, request.Size,
		price, guard.monthSpent(guard.now()), guard.config.MonthlyCapUSD)
	return droplet, nil
}

// deleteDroplet deletes a droplet of the guard's, or one bearing the race
// tag (a leftover of a ledger lost), and records when.
func (guard *Guard) deleteDroplet(ctx context.Context, id int) error {
	guard.mutex.Lock()
	defer guard.mutex.Unlock()
	index, mine := guard.life(id)
	if !mine {
		droplet, err := guard.provider.droplet(ctx, id)
		if err != nil {
			return err
		}
		if !contains(droplet.Tags, guard.config.Tag) {
			return fmt.Errorf("%w: droplet %d is not a race droplet", errRefused, id)
		}
	}
	err := guard.provider.deleteDroplet(ctx, id)
	if err != nil && !strings.Contains(err.Error(), "404") {
		return err
	}
	if mine && guard.lives[index].alive() {
		guard.lives[index].Deleted = guard.now()
		if err := guard.save(); err != nil {
			log.Printf("guard: the ledger: %v", err)
		}
	}
	return nil
}

func contains(items []string, item string) bool {
	for _, candidate := range items {
		if candidate == item {
			return true
		}
	}
	return false
}

// reap deletes the guard's droplets past their age, and marks deleted the
// ones DigitalOcean no longer has.
func (guard *Guard) reap(ctx context.Context) {
	ageMax := time.Duration(guard.config.AgeMaxMinutes) * time.Minute
	guard.mutex.Lock()
	var old []int
	for _, life := range guard.lives {
		if life.alive() && guard.now().Sub(life.Created) > ageMax {
			old = append(old, life.ID)
		}
	}
	guard.mutex.Unlock()
	for _, id := range old {
		log.Printf("guard: droplet %d is past %s: deleting it", id, ageMax)
		if err := guard.deleteDroplet(ctx, id); err != nil {
			log.Printf("guard: deleting %d: %v", id, err)
		}
	}
	tagged, err := guard.provider.dropletsTagged(ctx, guard.config.Tag)
	if err != nil {
		log.Printf("guard: listing droplets: %v", err)
		return
	}
	guard.mutex.Lock()
	defer guard.mutex.Unlock()
	changed := false
	for i, life := range guard.lives {
		found := false
		for _, droplet := range tagged {
			found = found || droplet.ID == life.ID
		}
		// Made a minute ago at least: a droplet just made may not be listed.
		if life.alive() && !found && guard.now().Sub(life.Created) > time.Minute {
			guard.lives[i].Deleted = guard.now()
			changed = true
		}
	}
	if changed {
		if err := guard.save(); err != nil {
			log.Printf("guard: the ledger: %v", err)
		}
	}
}

// --- the socket ------------------------------------------------------------

// commandGuard serves the guard on its socket until killed.
func commandGuard(ctx context.Context, args []string) error {
	flags := newFlags("guard")
	path := flags.String("config", "/etc/dragrace-guard/config.json", "the owner's config")
	flags.Parse(args)
	var config GuardConfig
	if err := readJSON(*path, &config); err != nil {
		return err
	}
	if err := config.check(); err != nil {
		return err
	}
	if err := tokenFromCredential("DIGITALOCEAN_TOKEN", "digitalocean-token"); err != nil {
		return err
	}
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	guard := &Guard{config: config, provider: do, now: time.Now}
	if err := guard.load(); err != nil {
		return fmt.Errorf("the ledger: %w", err)
	}
	os.Remove(config.Socket)
	listener, err := net.Listen("unix", config.Socket)
	if err != nil {
		return err
	}
	// The racer's group may connect; nobody else (the directory is the
	// guard's, mode 0750, group racer: SECURITY.md).
	if err := os.Chmod(config.Socket, 0o660); err != nil {
		return err
	}
	go func() {
		for {
			guard.reap(ctx)
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Minute):
			}
		}
	}()
	log.Printf("guard: on %s; month $%.2f of $%.2f", config.Socket, guard.monthSpent(time.Now()),
		config.MonthlyCapUSD)
	server := &http.Server{Handler: guard.handler(), ReadTimeout: time.Minute}
	go func() {
		<-ctx.Done()
		server.Close()
	}()
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// tokenFromCredential sets an environment variable from a systemd
// credential (LoadCredentialEncrypted=), if the service has one: the token
// then never sits in a unit file or on a command line.
func tokenFromCredential(variable, credential string) error {
	dir := os.Getenv("CREDENTIALS_DIRECTORY")
	if dir == "" || os.Getenv(variable) != "" {
		return nil
	}
	bytes, err := os.ReadFile(filepath.Join(dir, credential))
	if err != nil {
		return fmt.Errorf("credential %s: %w", credential, err)
	}
	return os.Setenv(variable, strings.TrimSpace(string(bytes)))
}

func (guard *Guard) handler() http.Handler {
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, value any, err error) {
		if err != nil {
			status := http.StatusBadGateway
			if errors.Is(err, errRefused) {
				status = http.StatusForbidden
			}
			http.Error(w, err.Error(), status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(value)
	}
	id := func(r *http.Request) (int, error) { return strconv.Atoi(r.PathValue("id")) }
	mux.HandleFunc("GET /sizes", func(w http.ResponseWriter, r *http.Request) {
		sizes, err := guard.provider.sizes(r.Context())
		reply(w, sizes, err)
	})
	mux.HandleFunc("POST /droplets", func(w http.ResponseWriter, r *http.Request) {
		var request DropletRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		droplet, err := guard.createDroplet(r.Context(), request)
		reply(w, droplet, err)
	})
	mux.HandleFunc("GET /droplets", func(w http.ResponseWriter, r *http.Request) {
		droplets, err := guard.provider.dropletsTagged(r.Context(), guard.config.Tag)
		reply(w, droplets, err)
	})
	mux.HandleFunc("GET /droplets/{id}", func(w http.ResponseWriter, r *http.Request) {
		number, err := id(r)
		if err != nil {
			http.Error(w, "not a droplet", http.StatusBadRequest)
			return
		}
		guard.mutex.Lock()
		_, mine := guard.life(number)
		guard.mutex.Unlock()
		if !mine {
			reply(w, nil, fmt.Errorf("%w: droplet %d is not the guard's", errRefused, number))
			return
		}
		droplet, err := guard.provider.droplet(r.Context(), number)
		reply(w, droplet, err)
	})
	mux.HandleFunc("DELETE /droplets/{id}", func(w http.ResponseWriter, r *http.Request) {
		number, err := id(r)
		if err != nil {
			http.Error(w, "not a droplet", http.StatusBadRequest)
			return
		}
		reply(w, struct{}{}, guard.deleteDroplet(r.Context(), number))
	})
	mux.HandleFunc("POST /keys", func(w http.ResponseWriter, r *http.Request) {
		var key SSHKey
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&key); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if !strings.HasPrefix(key.Name, sshKeyPrefix) {
			reply(w, nil, fmt.Errorf("%w: a key named %q", errRefused, key.Name))
			return
		}
		made, err := guard.provider.createKey(r.Context(), key.Name, key.PublicKey)
		reply(w, made, err)
	})
	mux.HandleFunc("GET /keys", func(w http.ResponseWriter, r *http.Request) {
		keys, err := guard.provider.keys(r.Context())
		ours := []SSHKey{}
		for _, key := range keys {
			if strings.HasPrefix(key.Name, sshKeyPrefix) {
				ours = append(ours, key)
			}
		}
		reply(w, ours, err)
	})
	mux.HandleFunc("DELETE /keys/{id}", func(w http.ResponseWriter, r *http.Request) {
		number, err := id(r)
		if err != nil {
			http.Error(w, "not a key", http.StatusBadRequest)
			return
		}
		keys, err := guard.provider.keys(r.Context())
		if err != nil {
			reply(w, nil, err)
			return
		}
		for _, key := range keys {
			if key.ID == number && strings.HasPrefix(key.Name, sshKeyPrefix) {
				reply(w, struct{}{}, guard.provider.deleteKey(r.Context(), number))
				return
			}
		}
		reply(w, nil, fmt.Errorf("%w: key %d is not a race key", errRefused, number))
	})
	return mux
}

// GuardClient is the racer's Provider: the guard, over its socket.
type GuardClient struct {
	client *http.Client
}

func newGuardClient(socket string) *GuardClient {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "unix", socket)
	}}
	return &GuardClient{client: &http.Client{Transport: transport, Timeout: 3 * time.Minute}}
}

func (guard *GuardClient) call(ctx context.Context, method, path string, body, into any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, "http://guard"+path, reader)
	if err != nil {
		return err
	}
	response, err := guard.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	text, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return err
	}
	if response.StatusCode == http.StatusForbidden {
		return fmt.Errorf("%w: %s", errRefused, strings.TrimSpace(string(text)))
	}
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("guard %s %s: %d: %s", method, path, response.StatusCode,
			strings.TrimSpace(string(text)))
	}
	if into == nil {
		return nil
	}
	return json.Unmarshal(text, into)
}

func (guard *GuardClient) createDroplet(ctx context.Context, request DropletRequest) (Droplet, error) {
	var droplet Droplet
	err := guard.call(ctx, http.MethodPost, "/droplets", request, &droplet)
	return droplet, err
}

func (guard *GuardClient) droplet(ctx context.Context, id int) (Droplet, error) {
	var droplet Droplet
	err := guard.call(ctx, http.MethodGet, fmt.Sprintf("/droplets/%d", id), nil, &droplet)
	return droplet, err
}

// dropletsTagged lists the race's droplets: the guard knows one tag.
func (guard *GuardClient) dropletsTagged(ctx context.Context, _ string) ([]Droplet, error) {
	var droplets []Droplet
	err := guard.call(ctx, http.MethodGet, "/droplets", nil, &droplets)
	return droplets, err
}

func (guard *GuardClient) deleteDroplet(ctx context.Context, id int) error {
	return guard.call(ctx, http.MethodDelete, fmt.Sprintf("/droplets/%d", id), nil, nil)
}

func (guard *GuardClient) createKey(ctx context.Context, name, public string) (SSHKey, error) {
	var key SSHKey
	err := guard.call(ctx, http.MethodPost, "/keys", SSHKey{Name: name, PublicKey: public}, &key)
	return key, err
}

func (guard *GuardClient) keys(ctx context.Context) ([]SSHKey, error) {
	var keys []SSHKey
	err := guard.call(ctx, http.MethodGet, "/keys", nil, &keys)
	return keys, err
}

func (guard *GuardClient) deleteKey(ctx context.Context, id int) error {
	return guard.call(ctx, http.MethodDelete, fmt.Sprintf("/keys/%d", id), nil, nil)
}

func (guard *GuardClient) sizes(ctx context.Context) ([]Size, error) {
	var sizes []Size
	err := guard.call(ctx, http.MethodGet, "/sizes", nil, &sizes)
	return sizes, err
}
