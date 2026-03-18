# Dylan - Deployment Guide

---

## Quick Start

```bash
git clone https://github.com/rhsev/dy.lan
cd dy.lan
docker compose up -d
```

Access the dashboard at `http://localhost:8080/dylan`

---

## Configuration

### Custom Redirects

Edit `config/redirects.yaml`:

```yaml
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

Redirects are hot-reloaded — no restart needed.

### Environment Variables

```yaml
environment:
  - PORT=80               # Server port
  - RUBY_ENV=production   # Environment mode
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
Dylan 1.0 - Async HTTP Server (Ruby 4.0)
Loading plugins from: /app/plugins
Server running on http://0.0.0.0:80
```

### Common Issues

- **Container won't start**: Check logs, verify no IP conflicts (macvlan) or port conflicts (bridge)
- **Can't access from network**: With bridge networking use `localhost:8080`. With macvlan ping the assigned IP.
- **Plugin not loading**: Check logs for errors. Plugins that error 5+ times are auto-disabled by the circuit breaker. Fix the plugin and restart: `docker restart dylan`

### Circuit Breaker

Plugins that error 5+ times are automatically disabled. Check status at `/dylan/stats`. Fix the plugin, restart Dylan, and it resets.

### Performance

- ~30 MB RAM
- ~20ms response time
- 5,000+ req/s (Mac mini M4), 2,000+ req/s (Synology DS224+)

```bash
# Benchmark
ab -n 1000 -c 10 http://localhost:8080/g/test
```
