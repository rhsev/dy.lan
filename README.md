# dy.lan

Server-side HTTP redirector for local networks with plugin-based automation

---
## What is Dylan?

Dylan turns local network URLs into workflows. 

Dylan is designed for local networks. It acts as a central entry point that translates simple URLs into actions - whether that's accessing a service, triggering an automation, or redirecting to an app-specific deep link.

Instead of remembering `192.168.1.73:8384`, you access `http://sync.lan`. 
Instead of complex scripts, you use `http://dy.lan/n/meeting` to search your notes for "meeting".

## Why Use Dylan?

**Workflow Shortcuts**  
Turn URLs into actions with pattern-based routing. Search notes, trigger shortcuts, or open specific documents via memorable URLs.

**Clean Local Services**  
Stop managing a reverse proxy for simple local tools. Dylan routes HTTP traffic to your services without the complexity of Traefik or nginx for non-HTTPS use cases.

**Extensible by Design**  
YAML configs for simple redirects. Ruby plugins for custom logic. Add new workflows without touching the core.

---

## Quick Start

**Requirements:** Docker

```bash
git clone https://github.com/rhsev/dylan
cd dylan
docker-compose up -d
```

Access the dashboard at `http://localhost:8080/dylan`

See [DEPLOYMENT.md](DEPLOYMENT.md) for full setup instructions.

---

## Use Cases

**Simple Redirects (YAML)**
```yaml
# config/redirects.yaml
redirects:
  - pattern: '^/g/(.+)$'
    target: 'https://google.com/search?q=${1}'
    
  - pattern: '^/gh/(.+)$'
    target: 'https://github.com/${1}'
```

Access: `http://dy.lan/g/ruby` → Google search  
Access: `http://dy.lan/gh/rhsev` → GitHub profile

**Host-Based Routing**
```yaml
# config/host-redirects.yaml
hosts:
  sync.lan: 'http://192.168.1.73:8384'
  dt.lan: 'http://192.168.1.73:8080'
```

Access: `http://sync.lan` → Syncthing  
Access: `http://dt.lan` → DEVONthink Server

**Workflow Automation (Ruby Plugin)**
```ruby
class NotesPlugin < Dylan::Plugin
  pattern %r{^/n/(.+)}
  
  def call(host, path, request)
    query = path.match(pattern)[1]
    Dylan::Response.redirect("shortcuts://run-shortcut?name=search_notes&input=#{query}")
  end
end
```

Access: `http://dy.lan/n/meeting` → Search Apple Notes for "meeting"

---

## Technical Notes

- Ruby 4.0 with async/fiber concurrency
- ~30 MB RAM inside the container
- ~20ms response time in local networks
- Handles thousands of requests per second (>5,000 req/s on Mac mini M4, >2,000 req/s on Synology DS224+)
- No database required

Built for 24/7 operation on home infrastructure.

---

## Features & Limitations

**What Dylan Does Well**
- Pattern-based URL routing
- YAML-based redirects (no coding required)
- Host/domain-level routing
- Lightweight reverse proxy for simple HTTP services
- Plugin architecture for custom workflows
- Hot-reload for YAML configs
- Circuit breaker (auto-disables broken plugins)

**What Dylan Doesn't Do**
- No TLS certificates
- No authentication

For HTTPS, put Caddy in front of Dylan — it handles certificates automatically.

---

## Companion: Milan

Dylan pairs with [mi.lan](https://github.com/rhsev/mi.lan), a lightweight script executor running on macOS. Dylan acts as the central router, Milan as the local executor. Together they bridge server-side logic with client-side automation.

```
http://mi.lan/mini/mail/abc123  →  Dylan  →  Milan (Mac)  →  script execution
```

---

## Project Status

**Shared as-is.** This project was built for use in personal automation workflows. The code is designed to be simple, transparent, and easy to extend with plugins.

**License:** MIT

---

## Credits

Built by Ralf Hülsmann ([GitHub](https://github.com/rhsev)), inspired by Brett Terpstra's Ruby tools and automation philosophy. Featured in Brett's [blog post](https://brettterpstra.com/2026/01/27/a-url-router-that-turns-your-local-network-into-a-workflow-engine/).

