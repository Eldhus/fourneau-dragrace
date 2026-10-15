package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
)

// The black box: the server machine's kernel messages and, every 10
// seconds, its memory, load and largest process, followed from the loader
// over one SSH session into a file there. A server that dies or stops
// answering takes its own logs with it; what led up to it is on the
// loader, which the racer reads before the droplets go. It costs the
// server a sampler waking every 10 s (a few ms of CPU).
//
// It ends with its session: SIGPIPE ignored, the sampler's write fails
// once the session is gone (the loader stopped it, or the race moved on),
// the loop ends, and its exit takes journalctl with it; on a server kept
// between ad-hoc races, no black box outlives its race. awk, not head,
// takes ps's first line: ps never writes into a closed pipe.
const blackBoxScript = `trap '' PIPE; ` +
	`journalctl -k -f -n 0 -o short-iso & ` +
	`trap 'kill $! 2>/dev/null' EXIT; ` +
	`while echo "$(date -u +%FT%TZ) sample:` +
	` $(awk '/^MemAvailable|^SwapFree/ {printf " %s %d MiB", $1, $2 / 1024}' /proc/meminfo)` +
	` load $(cut -d' ' -f1 /proc/loadavg)` +
	` largest $(ps -eo rss=,comm= --sort=-rss | awk 'NR == 1 {printf "%s %d MiB", $2, $1 / 1024}')"; ` +
	`do sleep 10; done`

// followServer starts the black box into path; stop ends it.
func followServer(ctx context.Context, server SSHMachine, path string) (stop func(), err error) {
	file, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	argv := append(server.options(), server.User+"@"+server.Host, "bash -c "+quote(blackBoxScript))
	cmd := exec.CommandContext(ctx, "ssh", argv...)
	cmd.Stdout, cmd.Stderr = file, file
	if err := cmd.Start(); err != nil {
		cancel()
		file.Close()
		return nil, err
	}
	go func() {
		// Ends when the server goes away, or at stop.
		err := cmd.Wait()
		fmt.Fprintf(file, "black box ended: %v\n", err)
		file.Close()
	}()
	return cancel, nil
}

// blackBoxTail is the black box's last lines, one line of text: what the
// server said last.
func blackBoxTail(path string, lines int) string {
	if path == "" {
		return ""
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		log.Printf("the black box: %v", err)
		return ""
	}
	all := strings.Split(strings.TrimSpace(string(bytes)), "\n")
	return strings.Join(all[max(0, len(all)-lines):], " | ")
}

// serverState is what the server machine says of itself after a step
// failed: when it booted (a reboot shows), its memory, and the kernel's
// last out-of-memory kill, segfault or invalid opcode.
func serverState(ctx context.Context, target Target) string {
	script := "echo \"up since $(uptime -s);\" " +
		"$(awk '/^MemAvailable/ {printf \"MemAvailable %d MiB;\", $2 / 1024}' /proc/meminfo); " +
		"dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|invalid opcode|segfault' | tail -n 2"
	state, err := target.Server.Shell(ctx, script)
	if err != nil {
		return "the server's state: " + err.Error()
	}
	return strings.Join(strings.Fields(state), " ")
}
