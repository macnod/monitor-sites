# monitor-sites

Monitor web sites. Send a Mattermost message if any site is down.

A Common Lisp program that monitors configured web sites by issuing
periodic HTTP GET requests. When a site is unreachable, it sends a
Mattermost notification. If the monitoring host itself loses internet
connectivity, it enters a retry loop and sends a different Mattermost
notification. Each site is alerted once per outage; a recovery
notification is sent when the site comes back.

## Quick Start

1. Copy the example config and edit it:

```sh
cp monitor-sites-conf.lisp.example monitor-sites-conf.lisp
```

2. Edit `monitor-sites-conf.lisp` with your sites, Mattermost
   credentials, and timing preferences.

3. Run locally:

```sh
./monitor-sites start
```

Or directly via Slime/REPL:

```lisp
(ql:quickload :monitor-sites)
(in-package :monitor-sites)
(main)
```

## The Shell Script

The `monitor-sites` script provides five commands:

| Command               | Description                                      |
|-----------------------|--------------------------------------------------|
| `start`               | Start the monitor (no-op if already running)    |
| `start-in-container`  | Run in foreground (for Docker/k8s entrypoint)   |
| `stop`                | Stop the monitor via the control server (no-op if not running) |
| `status`              | Print `up` or `down`                            |
| `logs`                | Tail the log file                               |

The script reads `:http-port` from the config to locate the control
server (default 8083). It uses `MONITOR_SITES_CONF` to find the config
file, falling back to `monitor-sites-conf.lisp` in the script
directory.

## Configuration

The config file is a quoted plist (`monitor-sites-conf.lisp`), read and
validated on every monitoring cycle, so changes take effect without
restarting. See `monitor-sites-conf.lisp.example` for the full format.

### Top-level keys

| Key                          | Type    | Description                                              |
|------------------------------|---------|----------------------------------------------------------|
| `:check-interval`            | integer | Seconds between full monitoring cycles (10–86400)       |
| `:retry-connectivity-time`   | integer | Seconds between connectivity retries when a site is down (10–3600) |
| `:lost-connectivity-time`    | integer | Seconds to sleep after connectivity is declared lost (1–86400) |
| `:max-connectivity-retries`  | integer | Retries before declaring connectivity lost (1–100)      |
| `:connectivity-urls`         | list    | URLs used to test internet connectivity (one is chosen at random each check) |
| `:mattermost-url`            | string  | Mattermost base URL                                     |
| `:mattermost-token`          | string  | Mattermost bot token                                    |
| `:mattermost-channel-id`     | string  | Mattermost channel ID for notifications                 |
| `:max-log-lines`             | integer | Log file truncated to this many lines each cycle (10–1000000) |
| `:http-port`                 | integer | Control server port (1–65535, default 8083)             |
| `:log-path`                  | string  | Path to the log file                                    |
| `:ca-directory`              | string  | Directory containing CA certificates                    |
| `:ca-cert`                   | string  | CA certificate bundle filename                          |
| `:user-agent`                | string  | Default User-Agent for HTTP requests                    |
| `:sites`                     | map     | Site definitions (see below)                            |

### Site entries

Each site is keyed by a keyword and must contain:

| Key             | Required | Description                                           |
|-----------------|----------|-------------------------------------------------------|
| `:name`         | yes      | Human-readable site name                             |
| `:url`          | yes      | URL to monitor                                       |
| `:expect`       | yes      | Regex string that must appear in the response body   |
| `:user-agent`   | no       | Per-site User-Agent override                         |
| `:ca-directory` | no       | Per-site CA directory override                       |
| `:ca-cert`      | no       | Per-site CA certificate override                     |

Example:

```lisp
:sites (:sinister-code (:name "Site #1"
                         :url "https://example.com"
                         :expect "Example Domain"))
```

### Config validation

Every config key is validated against a typed schema (`read-conf.lisp`)
on each cycle. Validation checks types, string length bounds, integer
ranges, list lengths, required vs optional fields, and unknown keys.
Sensitive values (Mattermost token, channel ID) are masked in log
output. If validation fails, the program continues with the last known
good config and logs the error (or terminates if no valid config has
been loaded yet).

### Config file location

The shell script resolves the config file in this order:

1. `MONITOR_SITES_CONF` environment variable
2. `monitor-sites-conf.lisp` in the script directory

## Behavior

### Monitoring cycle

Each cycle:

1. Truncate the log file to `:max-log-lines` (keeps most recent lines).
2. Check every site with an HTTP GET (TLS verification required).
3. A site is **up** if the HTTP status is 2xx **and** the `:expect`
   regex is found in the response body.
4. If a site is down, enter the connectivity retry loop.

### Connectivity retry loop

When a site is down:

1. Check internet connectivity by requesting one of the
   `:connectivity-urls`.
2. If connectivity is up: notify "site not responding" (once per site
   per outage), then return to the main loop.
3. If connectivity is down: retry every `:retry-connectivity-time`
   seconds, up to `:max-connectivity-retries` times.
4. If retries are exhausted: notify "lost connectivity" (once per
   outage) and sleep for `:lost-connectivity-time` seconds.

### Alert deduplication

- Each site is added to `*sites-down-notified*` when first reported
  down, and removed when it recovers. A site that goes down silently
  (notification send fails) will be retried on the next cycle.
- Connectivity loss is tracked with `*cx-lost-notified*`. When
  connectivity is restored, a "connectivity restored" notification is
  sent.

## Control Server

A Hunchentoot HTTP server runs on `127.0.0.1` at `:http-port`
(default 8083). It provides:

- `GET /health` — returns `200` with body `up`. Used by the shell
  script for `status` and `start` idempotency checks.
- `DELETE /health` — returns `200` then shuts down the process after
  0.5 seconds (allows the response to complete first).

The port is read from the config file. If the port changes between
cycles, the control server is restarted on the new port.

## Swank Server

A Swank server starts on port 4011 (bound to `0.0.0.0`), enabling
remote REPL access for debugging and live introspection. The
`eval-safely` function evaluates a string in the `:monitor-sites`
package and returns `(output values-string error-string)` without
ever entering the debugger.

## Kubernetes Deployment

### First-time setup

```sh
# Build and import the image
docker build -t monitor-sites:dev .
k3d image import monitor-sites:dev -c evo-x2

# Create namespace and apply manifests
kubectl create namespace monitor-sites
kubectl apply -f kube/configmap.yaml
kubectl apply -f kube/deployment.yaml
```

The ConfigMap is mounted at `/etc/monitor-sites/monitor-sites.conf`
and the `MONITOR_SITES_CONF` env var points to it.

> **Note:** `kube/configmap.yaml` contains real Mattermost credentials
> and is gitignored. It is not committed to the repository.

### Operations

| Operation           | Command                                                              |
|---------------------|----------------------------------------------------------------------|
| View pods           | `kubectl -n monitor-sites get pods`                                  |
| Tail logs           | `kubectl -n monitor-sites logs -f deploy/monitor-sites`              |
| Previous pod logs   | `kubectl -n monitor-sites logs --previous deploy/monitor-sites`      |
| Health check        | `kubectl -n monitor-sites exec deploy/monitor-sites -- curl -sS http://127.0.0.1:8083/health` |
| Restart             | `kubectl -n monitor-sites rollout restart deploy/monitor-sites`      |
| Stop (pause)        | `kubectl -n monitor-sites scale deploy/monitor-sites --replicas=0`   |
| Start (resume)      | `kubectl -n monitor-sites scale deploy/monitor-sites --replicas=1`   |
| Edit config         | Edit `kube/configmap.yaml` → `kubectl apply -f kube/configmap.yaml` → `kubectl -n monitor-sites rollout restart deploy/monitor-sites` |
| Swank REPL          | `kubectl -n monitor-sites port-forward deploy/monitor-sites 4011:4011` |
| Rebuild image       | `docker build -t monitor-sites:dev . && k3d image import monitor-sites:dev -c evo-x2 && kubectl -n monitor-sites rollout restart deploy/monitor-sites` |

Config is re-read every cycle, but ConfigMap volume updates have sync
lag. Always `rollout restart` after ConfigMap changes for deterministic
pickup.

## Dependencies

- [drakma](https://edicl.github.io/drakma/) — HTTP client
- [hunchentoot](https://edicl.github.io/hunchentoot/) — control server
- [cl-ppcre](https://edicl.github.io/cl-ppcre/) — regex (content matching)
- [flexi-streams](https://edicl.github.io/flexi-streams/) — byte stream decoding
- [swank](https://common-lisp.dev/project/slime/) — remote REPL
- dc-eclectic, dc-time, p-log — local projects by the same author

## License

MIT
