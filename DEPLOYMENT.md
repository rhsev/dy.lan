# Dylan 1.0 - Deployment Guide

Complete installation guide for Synology NAS, Mac/Linux, and infrastructure setup.

**Dylan 1.0**: First release of Ruby 4.0 async HTTP router with robustness features.

---

## Table of Contents

1. [Infrastructure Setup](#infrastructure-setup) (Required for Synology with macvlan)
2. [Synology Deployment](#synology-deployment)
3. [Mac/Linux Deployment](#maclinux-deployment)
4. [Configuration](#configuration)
5. [Troubleshooting](#troubleshooting)

---

## Infrastructure Setup

**Required if:** You're deploying on Synology with a static IP using macvlan network.

**Skip if:** You're using Mac/Linux with bridge networking.

### What is dockervlan?

A macvlan network allows containers to get their own IP addresses on your local network, making them accessible like any other device.

### Create the Network

1. **Create infrastructure directory**
   ```bash
   mkdir -p /volume1/docker/infrastructure
   cd /volume1/docker/infrastructure
   ```

2. **Create `docker-compose.yml`**
   ```yaml
   version: "3.8"

   services:
     network-keeper:
       image: alpine:latest
       command: tail -f /dev/null
       container_name: network-keeper
       restart: always
       networks:
         dockervlan:
           ipv4_address: 192.168.1.253

   networks:
     dockervlan:
       name: dockervlan
       driver: macvlan
       driver_opts:
         parent: ovs_eth2  # ← Adjust to your network interface
       enable_ipv6: false
       ipam:
         config:
           - subnet: "192.168.1.0/24"
             gateway: "192.168.1.1"
   ```

3. **Adjust for your network**
   - `parent: ovs_eth2` → Your network interface (check with `ip addr`)
   - `subnet: "192.168.1.0/24"` → Your network subnet
   - `gateway: "192.168.1.1"` → Your router IP

4. **Deploy via Portainer**
   - Stacks → Add Stack
   - Name: `infrastructure`
   - Upload the compose file
   - Deploy

5. **Verify**
   ```bash
   docker network ls | grep dockervlan
   # Should show: dockervlan
   ```

**Important:** Always assign static IPs to containers in this network! Docker can't auto-assign IPs safely in macvlan.

---

## Synology Deployment

### Prerequisites

- Synology NAS with Docker package installed
- Portainer (recommended) or SSH access
- Macvlan network created (see [Infrastructure Setup](#infrastructure-setup))

### Step 1: Upload Files

```bash
# Upload dylan folder to:
/volume1/docker/dylan
```

### Step 2: Configure IP Address

Edit `docker-compose.yml`:

```yaml
networks:
  existing_macvlan:
    ipv4_address: 192.168.1.252  # ← Change to available IP
```

**Choose an IP that:**
- Is in your network range (e.g., 192.168.1.x)
- Is not used by another device
- Is outside your DHCP range

### Step 3: Deploy in Portainer

1. Go to **Stacks** → **Add Stack**
2. **Name**: `dylan`
3. **Upload** or paste `docker-compose.yml`
4. Click **Deploy the stack**

### Step 4: Verify

```bash
# From any computer on your network:
curl http://192.168.1.252/dylan/routes

# Or open in browser:
# http://192.168.1.252/dylan
```

### Logs

View logs in Portainer or via SSH:

```bash
docker logs dylan -f
```

You should see:
```
==> Starting Dylan Server with Cron support
==> Starting crond...
==> Loaded crontab:
# Dylan Cron Jobs
*/5 * * * * /app/scripts/monitor.sh > /proc/1/fd/1 2>&1
==> Starting Dylan HTTP Server...
============================================================
Dylan 1.0 - Async HTTP Server (Ruby 4.0)
============================================================
Loading plugins from: /app/plugins
✅ Loading: 00-maintenance.rb
  Registered: MaintenancePlugin (pattern: /^\/dylan(\/|$)/)
✅ Loading: 10-checkip.rb
  Registered: CheckIPPlugin (pattern: /^\/$/)
...
🚀 Server running on http://0.0.0.0:80
   Performance: 6000+ req/s
   Features: Circuit breaker, Per-plugin timeouts, Safe plugin loading
```

---

## Mac/Linux Deployment

Dylan works great on Mac for local development and testing!

### Prerequisites

- **Mac**: OrbStack (recommended) or Docker Desktop
- **Linux**: Docker + Docker Compose

### Why OrbStack?

- **Fast**: Container startup ~2s vs ~20s on Docker Desktop
- **Light**: Uses less memory and CPU
- **Native**: Better Mac integration
- **Free**: For personal use

### Installation

**Install OrbStack (Mac):**
```bash
brew install orbstack
```

**Or Docker Desktop:**
```bash
brew install --cask docker
```

### Deploy

1. **Clone/copy Dylan 1.0**
   ```bash
   cd ~/Projects
   git clone <repo> dylan
   cd dylan
   ```

2. **Start Dylan**
   ```bash
   docker-compose -f docker-compose.mac.yml up -d
   ```

3. **View logs**
   ```bash
   docker logs dylan -f
   ```

4. **Access**
   ```
   http://localhost:8080/dylan
   http://localhost:8080/dylan/routes
   ```

### Development Workflow

```bash
# Edit a plugin
vim plugins/50-simple-redirects.rb

# Restart to reload
docker restart dylan

# Test
curl -I http://localhost:8080/g/test
```

### Stop Dylan

```bash
docker-compose -f docker-compose.mac.yml down
```

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

**Restart to apply:**
```bash
docker restart dylan
```

### Cron Jobs

Edit `config/crontab`:

```bash
# Network monitor (every 5 minutes)
*/5 * * * * /app/scripts/monitor.sh > /proc/1/fd/1 2>&1

# Daily cleanup (every day at 3am)
0 3 * * * /app/scripts/cleanup.sh > /proc/1/fd/1 2>&1
```

**Important:**
- Always redirect output to `/proc/1/fd/1 2>&1` to see logs
- Use absolute paths (`/app/scripts/...`)
- Make scripts executable: `chmod +x scripts/yourscript.sh`

### Environment Variables

Edit `docker-compose.yml`:

```yaml
environment:
  - PORT=80               # Server port
  - RUBY_ENV=production   # Environment mode
```

---

## Troubleshooting

### Container won't start

**Check logs:**
```bash
docker logs dylan
```

**Common issues:**
- IP address conflict (change in docker-compose.yml)
- Macvlan network doesn't exist (create infrastructure stack first)
- File permissions (chmod +x scripts/*.sh)

### Cron not running

**Verify cron is loaded:**
```bash
docker exec dylan crontab -l
```

**Check cron output in logs:**
```bash
docker logs dylan | grep monitor
```

**Test manually:**
```bash
docker exec dylan /app/scripts/monitor.sh
```

### Can't access from network

**Synology:**
- Check IP address is correct and not in DHCP range
- Verify dockervlan network exists: `docker network ls`
- Ping the IP: `ping 192.168.1.252`
- Check firewall rules

**Mac:**
- Use `localhost:8080` not the container IP
- Verify port mapping in docker-compose.mac.yml

### Plugin changes not applied

**Restart container:**
```bash
docker restart dylan
```

**Check logs for errors:**
```bash
docker logs dylan | grep -i error
```

**Check circuit breaker status:**
```bash
# Visit the stats page to see if any plugins are disabled
curl http://your-ip/dylan/stats?format=json
```

### High memory usage

**Dylan is lightweight** (~50MB), but if memory is high:
- Check for memory leaks in custom plugins
- Review async operations (ensure fibers terminate)
- Restart container: `docker restart dylan`

### Plugin Errors and Circuit Breaker

Dylan 1.0 includes automatic error handling:

**Circuit Breaker Protection:**
- Plugins that error 5+ times are automatically disabled
- Check disabled plugins at `/dylan/stats`
- Logs show error count: `Error count: 3/5`

**Common plugin errors:**
```bash
# Timeout errors (plugin took too long)
❌ ERROR in WeatherPlugin: TIMEOUT (>3.0s)

# General errors
❌ ERROR in MyPlugin: undefined method 'foo'
   Error count: 1/5

# Circuit breaker triggered
🚨 CIRCUIT BREAKER: MyPlugin disabled after 5 errors
```

**Fix disabled plugins:**
1. Check logs: `docker logs dylan | grep ERROR`
2. Fix the plugin code
3. Restart: `docker restart dylan`
4. Verify at `/dylan/stats` (disabled plugins shown in red)

### Performance Expectations

Dylan 1.0 performance benchmarks:
- **Simple redirects**: 6,100+ req/s
- **Dynamic content**: 5,700+ req/s
- **Slow APIs**: Handled concurrently (non-blocking)

**Test performance:**
```bash
# Install Apache Bench
brew install httpd  # Mac
apt install apache2-utils  # Linux

# Benchmark simple redirect
ab -n 1000 -c 10 http://localhost:8080/g/test

# You should see 5000+ requests/second
```

### Ruby 4.0 Features

Dylan leverages Ruby 4.0 for better performance:
- Fiber-based async concurrency
- Modern syntax (`it` parameter in core)
- No JIT (ZJIT disabled for better latency)

### Troubleshooting Summary

1. **Check logs**: `docker logs dylan`
2. **Verify configuration** files (docker-compose.yml, config/*)
3. **Test plugins** individually at `/dylan/test?path=/your/path`
4. **Monitor stats** at `/dylan/stats` for circuit breaker status
5. **Review DEVELOPMENT.md** for detailed plugin debugging

