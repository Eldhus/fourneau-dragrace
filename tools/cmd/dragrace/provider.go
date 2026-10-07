package main

import (
	"context"
	"fmt"
	"time"
)

// Provider is what a race asks of DigitalOcean: DigitalOcean itself (a
// race from the owner's machine, the token in its environment), or the
// guard (the racer: guard.go holds the token and the budget, and the racer
// asks it over a Unix socket).
type Provider interface {
	createDroplet(ctx context.Context, request DropletRequest) (Droplet, error)
	droplet(ctx context.Context, id int) (Droplet, error)
	dropletsTagged(ctx context.Context, tag string) ([]Droplet, error)
	deleteDroplet(ctx context.Context, id int) error
	createKey(ctx context.Context, name, public string) (SSHKey, error)
	keys(ctx context.Context) ([]SSHKey, error)
	deleteKey(ctx context.Context, id int) error
	sizes(ctx context.Context) ([]Size, error)
}

// waitActive polls until the droplet is active with both addresses.
func waitActive(ctx context.Context, provider Provider, id int) (Droplet, error) {
	for range 120 {
		droplet, err := provider.droplet(ctx, id)
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
