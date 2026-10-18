package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// notify pushes the site's failure to the owner's phone, through ntfy.sh.
// The uptime check misses a crash: the site is back within seconds
// (Restart=always), between two of its probes. The site's OnFailure=
// starts dragrace-site-crashed.service, which runs this: systemd gives it
// the failure ($MONITOR_*, systemd 251 and later), the topic as a
// credential (LoadCredential=, from /etc/dragrace-host/ntfy-topic, which
// site install-server writes from the owner's keyring), and a state
// directory. The daily restart is a clean stop and starts nothing.
//
// The topic is the only secret: an unreserved ntfy.sh topic is anyone's
// who knows its name, and an ntfy.sh access token would be the whole
// account (they have no scopes). The message names the failure and the
// restart count, never the site's log.

// ntfyServer is where the alert is posted: ntfy.sh, the topic appended.
const ntfyServer = "https://ntfy.sh/"

// notifyQuiet is the least time between two alerts: a crash every few
// seconds is one alert, not a storm (the uptime check says it is down).
const notifyQuiet = 5 * time.Minute

// ntfyTopic is ntfy's topic grammar.
var ntfyTopic = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// siteFailure is a failure as systemd hands it to an OnFailure= unit.
type siteFailure struct {
	Unit     string // MONITOR_UNIT: dragrace-site.service
	Result   string // MONITOR_SERVICE_RESULT: core-dump, signal, oom-kill, exit-code, timeout
	Code     string // MONITOR_EXIT_CODE: dumped, killed, exited
	Status   string // MONITOR_EXIT_STATUS: ABRT, KILL, 1
	Restarts string // NRestarts: since the site was last started by hand or by its timer
}

// notifier posts alerts, its effects apart so a test can stand in.
type notifier struct {
	server string // ntfyServer
	topic  string
	state  string // the last alert's time, in a file here
	now    func() time.Time
	client *http.Client
}

func commandNotify(ctx context.Context, args []string) error {
	flags := newFlags("notify")
	flags.Parse(args)
	credentials, state := os.Getenv("CREDENTIALS_DIRECTORY"), os.Getenv("STATE_DIRECTORY")
	if credentials == "" || state == "" {
		return fmt.Errorf("notify runs as dragrace-site-crashed.service: " +
			"no credentials or state directory")
	}
	topic, err := readTopic(filepath.Join(credentials, "ntfy-topic"))
	if err != nil {
		return err
	}
	failure := siteFailure{Unit: os.Getenv("MONITOR_UNIT"),
		Result: os.Getenv("MONITOR_SERVICE_RESULT"), Code: os.Getenv("MONITOR_EXIT_CODE"),
		Status: os.Getenv("MONITOR_EXIT_STATUS")}
	if failure.Unit == "" {
		return fmt.Errorf("no MONITOR_UNIT: notify is started by the site's OnFailure=")
	}
	failure.Restarts = unitRestarts(ctx, failure.Unit)
	alert := notifier{server: ntfyServer, topic: topic, state: state, now: time.Now,
		client: &http.Client{Timeout: 30 * time.Second}}
	return alert.send(ctx, failure)
}

// readTopic reads the topic, checked against ntfy's grammar. The error
// never shows it.
func readTopic(path string) (string, error) {
	bytes, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	topic := strings.TrimSpace(string(bytes))
	if !ntfyTopic.MatchString(topic) {
		return "", fmt.Errorf("%s: not an ntfy topic (letters, digits, - and _, at most 64)", path)
	}
	return topic, nil
}

// unitRestarts is systemd's NRestarts for a unit; "?" when it cannot say.
func unitRestarts(ctx context.Context, unit string) string {
	output, err := exec.CommandContext(ctx, "systemctl", "show", "-p", "NRestarts", "--value",
		unit).Output()
	restarts := strings.TrimSpace(string(output))
	if err != nil || restarts == "" {
		return "?"
	}
	return restarts
}

// send posts the alert, unless one went within notifyQuiet.
func (alert notifier) send(ctx context.Context, failure siteFailure) error {
	stamp := filepath.Join(alert.state, "last-sent")
	if last, err := os.ReadFile(stamp); err == nil {
		sent, err := time.Parse(time.RFC3339, strings.TrimSpace(string(last)))
		if err == nil && alert.now().Sub(sent) < notifyQuiet {
			log.Printf("%s: %s; not sent, one went at %s", failure.Unit, failure.Result,
				sent.Format(time.RFC3339))
			return nil
		}
	}
	title, body := failureMessage(failure)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, alert.server+alert.topic,
		strings.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Title", title)
	request.Header.Set("Priority", "5")
	request.Header.Set("Tags", "rotating_light")
	response, err := alert.client.Do(request)
	if err != nil {
		var failed *url.Error // its message has the URL, and so the topic
		if errors.As(err, &failed) {
			err = failed.Err
		}
		return fmt.Errorf("ntfy: %w", err)
	}
	defer response.Body.Close()
	answer, _ := io.ReadAll(io.LimitReader(response.Body, 512))
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("ntfy: %d: %s", response.StatusCode, strings.TrimSpace(string(answer)))
	}
	log.Printf("%s: %s; sent", failure.Unit, failure.Result)
	return os.WriteFile(stamp, []byte(alert.now().UTC().Format(time.RFC3339)+"\n"), 0o600)
}

// failureMessage is the alert: the failure in a few words, and where its
// log is.
func failureMessage(failure siteFailure) (title, body string) {
	verb := "failed"
	switch failure.Result {
	case "core-dump", "signal", "oom-kill", "watchdog":
		verb = "crashed"
	}
	title = "dragrace site " + verb
	how := failure.Result
	if failure.Code != "" || failure.Status != "" {
		how += " (" + strings.TrimSpace(failure.Code+" "+failure.Status) + ")"
	}
	body = fmt.Sprintf("%s: %s; restarted %s times since its last start.\n"+
		"journalctl -u %s", failure.Unit, how, failure.Restarts, failure.Unit)
	return title, body
}
