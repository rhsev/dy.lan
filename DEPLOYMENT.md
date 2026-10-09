# Dylan - Deployment Guide

---

## Quick Start

```bash
git clone https://github.com/rhsev/dy.lan
cd dy.lan
docker compose up -d
```

Access the dashboard at `http://localhost:8080/dylan`

After the first build, updates only require a restart, no rebuild:

```bash
git pull
docker restart dylan        # or: curl http://localhost:8080/reload
```

`/reload` ends the Ruby process and Docker's restart policy brings the
container back (5–15 s), so it picks up `server.rb` and `lib/` as well.

Only Gemfile changes require a new image build (`docker compose up -d --build`).

---

## Configuration

### Custom Redirects

Edit `config/redirects.yaml`:

```yaml
domains: ['dy.lan']   # optional: only answer for these Host headers
redirects:
  # Google search
  - pattern: '^/g/(.+)$'
    target: 'https://google.com/search?q=${1}'
    description: 'Google search shortcut'

  # GitHub repos
  - pattern: '^/gh/(.+)/(.+)$'
    target: 'https://github.com/${1}/${2}'
    description: 'GitHub repository'

  # YouTube search
  - pattern: '^/yt/(.+)$'
    target: 'https://youtube.com/results?search_query=${1}'
    description: 'YouTube search'
```

Redirects are hot-reloaded, so no restart is needed.

With `domains:` set, a request for any other host falls through to the next
plugin: `curl http://localhost:8080/g/ruby` is a 404 while
`curl -H 'Host: dy.lan' http://localhost:8080/g/ruby` redirects.

### Environment Variables

```yaml
environment:
  - PORT=80               # Server port
  - RUBY_ENV=production   # Environment mode
  - TZ=Europe/Berlin      # Container time zone (cron, log timestamps)
  # - DYLAN_DEBUG=1       # log every request, not only status >= 400
  # - DYLAN_QUIET=1       # log no requests at all
```

---

> **Advanced: Own IP via macvlan**
> For host-based routing (e.g. `http://sync.lan` → Syncthing), give Dylan its own IP on your local network using a Docker macvlan network. Create the network with `docker network create --driver macvlan --subnet=192.168.1.0/24 --gateway=192.168.1.1 --opt parent=eth0 dockervlan`, then assign a static IP in `docker-compose.yml`. See the [Docker macvlan docs](https://docs.docker.com/network/macvlan/) for details.

---

## Troubleshooting

### Logs

```bash
docker logs dylan -f
```

You should see:
```
Dylan 1.1 - Async Dynamic HTTP Router
✅ Loading: 00-host-redirects.rb
…
Loaded 14/14 plugin file(s)
Server running on port 80
```

### Common Issues

- **Container won't start**: Check logs, verify no IP conflicts (macvlan) or port conflicts (bridge)
- **Can't access from network**: With bridge networking use `localhost:8080`. With macvlan ping the assigned IP.
- **Plugin not loading**: Check logs for `FAILED to load`. Fix the plugin and `/reload`.
- **A route answers 500, 503 or 504**: the plugin that owns the path failed: 500 is an exception, 504 its timeout, 503 the circuit breaker (below). The log has the error and its location (`docker logs dylan | grep "ERROR in"`).

### Circuit Breaker

A plugin with 5 errors within 60 s is disabled for 5 minutes and re-enabled automatically afterwards. While it is off, its paths answer 503. Errors and disabled plugins show at `/dylan/stats`; a `/reload` clears the state at once.

### Performance

- ~35 MB RAM (resident, steady state)
- A few milliseconds per request on the LAN
- 2,000+ req/s on a Synology DS224+, 15,000+ req/s on a Mac mini M4

```bash
# Latency, async concurrency and a short load run, with expected statuses
DYLAN_HOST=localhost DYLAN_PORT=8080 ruby test_performance.rb

# Throughput only
wrk -t2 -c20 -d10s -H 'Host: dy.lan' http://localhost:8080/dylan/stats
```
