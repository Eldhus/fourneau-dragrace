package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
	"unicode"
)

// DigitalOcean is the few calls of DigitalOcean's API a race makes. The
// token needs only the scopes SECURITY.md lists.
type DigitalOcean struct {
	token  string
	client *http.Client
}

func newDigitalOcean() (*DigitalOcean, error) {
	// A token pasted into a keyring often brings a space or a carriage
	// return with it; HTTP refuses such a header. Trim the ends, refuse the
	// middle, and never print the token.
	token := strings.TrimSpace(os.Getenv("DIGITALOCEAN_TOKEN"))
	if token == "" {
		return nil, fmt.Errorf("DIGITALOCEAN_TOKEN is not set (SECURITY.md)")
	}
	if strings.ContainsFunc(token, unicode.IsSpace) {
		return nil, fmt.Errorf("DIGITALOCEAN_TOKEN has whitespace inside it: store the token alone (SECURITY.md)")
	}
	return &DigitalOcean{token: token, client: &http.Client{Timeout: 60 * time.Second}}, nil
}

func (do *DigitalOcean) call(ctx context.Context, method, path string, body, into any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, "https://api.digitalocean.com"+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+do.token)
	request.Header.Set("Content-Type", "application/json")
	response, err := do.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return err
	}
	if response.StatusCode >= 300 {
		return fmt.Errorf("DigitalOcean %s %s: %s: %s", method, path, response.Status, payload)
	}
	if into != nil && len(payload) > 0 {
		return json.Unmarshal(payload, into)
	}
	return nil
}

type Droplet struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	Tags      []string  `json:"tags"`
	SizeSlug  string    `json:"size_slug"`
	Networks  struct {
		V4 []struct {
			IPAddress string `json:"ip_address"`
			Type      string `json:"type"`
		} `json:"v4"`
	} `json:"networks"`
}

func (droplet Droplet) address(kind string) string {
	for _, network := range droplet.Networks.V4 {
		if network.Type == kind {
			return network.IPAddress
		}
	}
	return ""
}

type DropletRequest struct {
	Name       string   `json:"name"`
	Region     string   `json:"region"`
	Size       string   `json:"size"`
	Image      string   `json:"image"`
	SSHKeys    []int    `json:"ssh_keys"`
	Tags       []string `json:"tags"`
	UserData   string   `json:"user_data,omitempty"`
	Monitoring bool     `json:"monitoring"`
	IPv6       bool     `json:"ipv6"`
}

func (do *DigitalOcean) createDroplet(ctx context.Context, request DropletRequest) (Droplet, error) {
	var response struct {
		Droplet Droplet `json:"droplet"`
	}
	err := do.call(ctx, http.MethodPost, "/v2/droplets", request, &response)
	return response.Droplet, err
}

func (do *DigitalOcean) droplet(ctx context.Context, id int) (Droplet, error) {
	var response struct {
		Droplet Droplet `json:"droplet"`
	}
	err := do.call(ctx, http.MethodGet, fmt.Sprintf("/v2/droplets/%d", id), nil, &response)
	return response.Droplet, err
}

func (do *DigitalOcean) dropletsTagged(ctx context.Context, tag string) ([]Droplet, error) {
	var response struct {
		Droplets []Droplet `json:"droplets"`
	}
	err := do.call(ctx, http.MethodGet, "/v2/droplets?per_page=200&tag_name="+tag, nil, &response)
	return response.Droplets, err
}

func (do *DigitalOcean) deleteDroplet(ctx context.Context, id int) error {
	return do.call(ctx, http.MethodDelete, fmt.Sprintf("/v2/droplets/%d", id), nil, nil)
}

// waitActive polls until the droplet is active with both addresses.
func (do *DigitalOcean) waitActive(ctx context.Context, id int) (Droplet, error) {
	for range 120 {
		droplet, err := do.droplet(ctx, id)
		if err != nil {
			return droplet, err
		}
		if droplet.Status == "active" && droplet.address("public") != "" &&
			droplet.address("private") != "" {
			return droplet, nil
		}
		select {
		case <-ctx.Done():
			return droplet, ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
	return Droplet{}, fmt.Errorf("droplet %d not active after 10 minutes", id)
}

type SSHKey struct {
	ID        int    `json:"id"`
	Name      string `json:"name"`
	PublicKey string `json:"public_key"`
}

func (do *DigitalOcean) createKey(ctx context.Context, name, public string) (SSHKey, error) {
	var response struct {
		Key SSHKey `json:"ssh_key"`
	}
	body := map[string]string{"name": name, "public_key": public}
	err := do.call(ctx, http.MethodPost, "/v2/account/keys", body, &response)
	return response.Key, err
}

// ensureKey registers a public key, or returns the registration it already
// has: DigitalOcean refuses the same key twice, and a second provision
// (after a failed first) must not.
func (do *DigitalOcean) ensureKey(ctx context.Context, name, public string) (SSHKey, error) {
	keys, err := do.keys(ctx)
	if err != nil {
		return SSHKey{}, err
	}
	for _, key := range keys {
		if strings.TrimSpace(key.PublicKey) == public {
			return key, nil
		}
	}
	return do.createKey(ctx, name, public)
}

func (do *DigitalOcean) keys(ctx context.Context) ([]SSHKey, error) {
	var response struct {
		Keys []SSHKey `json:"ssh_keys"`
	}
	err := do.call(ctx, http.MethodGet, "/v2/account/keys?per_page=200", nil, &response)
	return response.Keys, err
}

func (do *DigitalOcean) deleteKey(ctx context.Context, id int) error {
	return do.call(ctx, http.MethodDelete, fmt.Sprintf("/v2/account/keys/%d", id), nil, nil)
}

// Size is one droplet size and where it can be made.
type Size struct {
	Slug         string   `json:"slug"`
	Available    bool     `json:"available"`
	Regions      []string `json:"regions"`
	VCPUs        int      `json:"vcpus"`
	MemoryMiB    int      `json:"memory"`
	PriceHourly  float64  `json:"price_hourly"`
	PriceMonthly float64  `json:"price_monthly"`
	Description  string   `json:"description"`
}

func (do *DigitalOcean) sizes(ctx context.Context) ([]Size, error) {
	var response struct {
		Sizes []Size `json:"sizes"`
	}
	err := do.call(ctx, http.MethodGet, "/v2/sizes?per_page=200", nil, &response)
	return response.Sizes, err
}

// checkSizes fails, naming every problem at once, when a size the race
// needs does not exist, is not available, or is not offered in its region,
// or when a class's loader has no more vCPUs than its server.
func checkSizes(ctx context.Context, do *DigitalOcean, cloud Cloud) (map[string]float64, error) {
	sizes, err := do.sizes(ctx)
	if err != nil {
		return nil, err
	}
	// Each size's hourly price, for the race's cost (timing.go).
	prices := map[string]float64{}
	for _, size := range sizes {
		prices[size.Slug] = size.PriceHourly
	}
	bySlug := map[string]Size{}
	for _, size := range sizes {
		bySlug[size.Slug] = size
	}
	var wanted []string
	var problems []string
	for _, class := range cloud.Servers {
		wanted = append(wanted, class.Size, class.LoaderSize)
		server, loader := bySlug[class.Size], bySlug[class.LoaderSize]
		if loader.VCPUs <= server.VCPUs {
			problems = append(problems, fmt.Sprintf("%s: loader %s (%d vCPUs) is not bigger than server %s (%d)",
				class.Name, class.LoaderSize, loader.VCPUs, class.Size, server.VCPUs))
		}
	}
	for _, slug := range wanted {
		size, found := bySlug[slug]
		switch {
		case !found:
			problems = append(problems, slug+": no such size")
		case !size.Available:
			problems = append(problems, slug+": not available")
		case !slices.Contains(size.Regions, cloud.Region):
			problems = append(problems, fmt.Sprintf("%s: not in %s (offered in %s)",
				slug, cloud.Region, strings.Join(size.Regions, ", ")))
		}
	}
	if len(problems) > 0 {
		return nil, fmt.Errorf("race.json's cloud sizes: %s", strings.Join(problems, "; "))
	}
	return prices, nil
}

// commandSizes prints the droplet sizes whose slug starts with -prefix
// (CPU-optimized by default), with prices and the regions offering them
// (race.json's first, marked): the numbers a change to race.json's sizes
// and region is decided on.
func commandSizes(ctx context.Context, root string, args []string) error {
	flags := newFlags("sizes")
	prefix := flags.String("prefix", "c", "slugs starting with this")
	flags.Parse(args)
	race, err := loadRace(root)
	if err != nil {
		return err
	}
	do, err := newDigitalOcean()
	if err != nil {
		return err
	}
	sizes, err := do.sizes(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("%-22s %5s %8s %9s %9s  %-36s regions (*%s)\n", "slug", "vcpus", "memory", "$/hour",
		"$/month", "description", race.Cloud.Region)
	for _, size := range sizes {
		if !strings.HasPrefix(size.Slug, *prefix) {
			continue
		}
		regions := "unavailable"
		if size.Available {
			marked := make([]string, 0, len(size.Regions))
			for _, region := range size.Regions {
				if region == race.Cloud.Region {
					region = "*" + region
				}
				marked = append(marked, region)
			}
			slices.Sort(marked)
			regions = strings.Join(marked, " ")
		}
		fmt.Printf("%-22s %5d %6dMi %9.4f %9.2f  %-36s %s\n", size.Slug, size.VCPUs, size.MemoryMiB,
			size.PriceHourly, size.PriceMonthly, size.Description, regions)
	}
	return nil
}
