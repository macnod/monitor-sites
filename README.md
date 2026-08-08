# monitor-sites

Monitor web sites. Send a Mattermost message if any site is down.

A Common Lisp program that monitors configured web sites by issuing
periodic HTTP GET requests. When a site is unreachable, it sends a
Mattermost notification. If the monitoring host itself loses internet
connectivity, it enters a retry loop and sends a different Mattermost
notification.

## Quick Start

1. Copy the example config and edit it:

```sh
cp monitor-sites.conf.example monitor-sites.conf
```

2. Edit `monitor-sites.conf` with your sites, Mattermost credentials,
   and timing preferences.

3. Run locally:

```sh
./monitor-sites.sh
```

Or directly via Slime/REPL:

```lisp
(ql:quickload :monitor-sites)
(in-package :monitor-sites)
(main)
```

## Configuration

The config file is a quoted plist read on every monitoring cycle, so
changes take effect without restarting. See
`monitor-sites.conf.example` for the full format.

Key settings:

- `:check-interval` — seconds between full monitoring cycles (default 300)
- `:connectivity-url` — URL used to test internet connectivity
- `:mm-url`, `:mm-token`, `:mm-channel-id` — Mattermost credentials
- `:sites` — list of site plists with `:name`, `:url`, and optional
  `:expect` (string that must appear in the response body)

### Config file location

Resolved in this order:

1. `MONITOR_SITES_CONF` environment variable
2. `monitor-sites.conf` in the program directory
3. `~/monitor-sites.conf`

## Behavior

- Each cycle: check every site with an HTTP GET.
- If a site is down and connectivity is fine: send "site not
  responding" notification.
- If a site is down and connectivity is also down: retry up to
  `:max-connectivity-retries` times, then send "lost connectivity"
  notification (once per outage).
- When connectivity is restored: send "connectivity restored"
  notification.
- Log file is truncated to `:max-log-lines` at the top of each cycle.

## Kubernetes Deployment

```sh
# Create namespace
kubectl create namespace monitor-sites

# Apply manifests
kubectl apply -f kube/

# Update config (picked up on next cycle, no restart needed)
kubectl edit configmap monitor-sites -n monitor-sites
```

The ConfigMap is mounted at `/etc/monitor-sites/monitor-sites.conf`
and the `MONITOR_SITES_CONF` env var points to it.

## Dependencies

- [drakma](https://edicl.github.io/drakma/) — HTTP client
- [cl-ppcre](https://edicl.github.io/cl-ppcre/) — regex (for content matching)
- dc-eclectic, dc-time, p-log — local projects

## License

MIT
