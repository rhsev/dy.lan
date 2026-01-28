# Dylan 1.0 - Development Guide

Complete guide for developing plugins, testing, and extending Dylan 1.0.

---

## Table of Contents

1. [Plugin Development](#plugin-development)
2. [Development Environment](#development-environment)
3. [Testing Plugins](#testing-plugins)
4. [Debugging](#debugging)
5. [Best Practices](#best-practices)
6. [Advanced Topics](#advanced-topics)

---

## Plugin Development

### Plugin Architecture

Dylan uses a simple plugin system:

1. **Base Class**: All plugins inherit from `Dylan::Plugin`
2. **Pattern Matching**: Define regex patterns to match requests
3. **Handler Method**: Implement `call(host, path, request)` to handle requests
4. **Auto-Registration**: Plugins are automatically discovered and loaded
5. **Timeout Control**: Optional per-plugin timeout configuration (default 500ms)

### Your First Plugin

Create `plugins/70-wikipedia.rb`:

```ruby
# frozen_string_literal: true

class WikipediaPlugin < Dylan::Plugin
  # Define URL pattern to match
  pattern(%r{^/w/(.+)$})

  # Handle matched requests
  def call(host, path, request)
    # Extract search term from URL
    match = path.match(%r{^/w/(.+)$})
    term = match[1]

    # Redirect to Wikipedia
    Dylan::Response.redirect("https://en.wikipedia.org/wiki/#{term}")
  end
end
```

**Test it:**
```bash
curl -I http://localhost:8080/w/Ruby
# → 302 redirect to https://en.wikipedia.org/wiki/Ruby
```

### Plugin with Custom Timeout

For plugins that make external API calls:

```ruby
class SlowAPIPlugin < Dylan::Plugin
  pattern(%r{^/api/external})
  timeout(3.0)  # Allow up to 3 seconds (default is 500ms)

  def call(host, path, request)
    # Make external API call
    # Use Async::Task.current.sleep to yield CPU
    Async::Task.current.sleep(2)

    Dylan::Response.json({ status: "ok" })
  end
end
```

### Plugin Lifecycle

1. **Load**: Plugins are loaded alphabetically by filename
   - `00-*.rb` loads before `50-*.rb`
   - Use numeric prefixes to control order

2. **Registration**: `Dylan::Plugin.inherited` auto-registers plugins

3. **Routing**: Router checks patterns in load order
   - First matching pattern wins
   - Once a plugin returns a response, routing stops
   - Failed plugins don't stop routing (error handling continues to next plugin)

4. **Reload**: Restart container to reload plugins
   ```bash
   docker restart dylan
   ```

---

## Response Helpers

Dylan provides helpers in `Dylan::Response` for common HTTP responses:

### Redirects

```ruby
# 302 Found (temporary redirect)
Dylan::Response.redirect("https://example.com")

# Example: Redirect with captured groups
def call(host, path, request)
  match = path.match(%r{^/gh/(.+)/(.+)$})
  Dylan::Response.redirect("https://github.com/#{match[1]}/#{match[2]}")
end
```

### HTML Responses

```ruby
# 200 OK with HTML
html_content = <<~HTML
  <!DOCTYPE html>
  <html>
    <head><title>Hello</title></head>
    <body><h1>Hello World</h1></body>
  </html>
HTML

Dylan::Response.html(html_content)

# Custom status code
Dylan::Response.html("<h1>Created</h1>", status: 201)
```

### JSON Responses

```ruby
# 200 OK with JSON
data = {
  status: "ok",
  temperature: 23,
  city: "Berlin"
}

Dylan::Response.json(data)

# Custom status code
Dylan::Response.json({ error: "Not authorized" }, status: 401)
```

### Plain Text

```ruby
# 200 OK with plain text
Dylan::Response.text("Hello World")

# Custom status code
Dylan::Response.text("Created", status: 201)
```

### Error Responses

```ruby
# 404 Not Found
Dylan::Response.not_found

# Custom error
Dylan::Response.error(500, "Internal Server Error")
Dylan::Response.error(403, "Access Denied")
```

---

## Pattern Matching

### Regex Patterns

Plugins use Ruby regex patterns:

```ruby
# Match /g/anything
pattern(%r{^/g/(.+)$})

# Match /user/123/profile
pattern(%r{^/user/(\d+)/profile$})

# Match /search with query params (note: path only, no query string)
pattern(%r{^/search$})

# Match host (for multi-tenant setups)
pattern(%r{^api\.example\.com$})
```

### Capture Groups

Extract data from URLs using capture groups:

```ruby
class GitHubPlugin < Dylan::Plugin
  pattern(%r{^/gh/(.+)/(.+)$})

  def call(host, path, request)
    match = path.match(%r{^/gh/(.+)/(.+)$})
    username = match[1]
    repo = match[2]

    Dylan::Response.redirect("https://github.com/#{username}/#{repo}")
  end
end
```

**Test:**
```bash
curl -I http://localhost:8080/gh/rails/rails
# → Redirects to https://github.com/rails/rails
```

### Named Captures

Use named captures for clarity:

```ruby
pattern(%r{^/user/(?<id>\d+)/(?<action>\w+)$})

def call(host, path, request)
  match = path.match(%r{^/user/(?<id>\d+)/(?<action>\w+)$})
  user_id = match[:id]
  action = match[:action]

  Dylan::Response.text("User #{user_id}, Action: #{action}")
end
```

---

## Working with Requests

### Request Object

The `request` parameter is an `Async::HTTP::Protocol::Request`:

```ruby
def call(host, path, request)
  # Request method (GET, POST, etc.)
  method = request.method

  # Request headers
  user_agent = request.headers['user-agent']

  # Request body (for POST/PUT)
  body = request.body&.read

  # Path and host
  puts "Method: #{method}"
  puts "Host: #{host}"
  puts "Path: #{path}"
  puts "User-Agent: #{user_agent}"

  Dylan::Response.text("Request logged")
end
```

### Query Parameters

Parse query strings manually:

```ruby
require 'uri'

def call(host, path, request)
  # Parse query string from path
  uri = URI.parse("http://dummy#{path}")
  params = URI.decode_www_form(uri.query || "").to_h

  search_term = params['q']

  Dylan::Response.json({ query: search_term })
end
```

**Test:**
```bash
curl http://localhost:8080/search?q=ruby
# → {"query":"ruby"}
```

### Reading POST Data

```ruby
def call(host, path, request)
  if request.method == 'POST'
    # Read body
    body = request.body&.read

    # Parse JSON
    require 'json'
    data = JSON.parse(body) rescue {}

    Dylan::Response.json({ received: data })
  else
    Dylan::Response.error(405, "Method Not Allowed")
  end
end
```

---

## Development Environment

### Local Setup (Mac)

1. **Install Ruby 4.0** (if testing without Docker)
   ```bash
   # Ruby 4.0 via rbenv/asdf
   rbenv install 4.0.1
   rbenv local 4.0.1
   ```

2. **Install dependencies**
   ```bash
   cd dylan
   bundle install
   ```

3. **Run Dylan locally** (without Docker)
   ```bash
   bundle exec ruby server.rb
   ```

4. **Or use Docker** (recommended)
   ```bash
   docker-compose -f docker-compose.mac.yml up
   ```

### File Structure

```
dylan/
├── server.rb                 # Main server entry point
├── Gemfile                   # Ruby dependencies
│
├── lib/
│   ├── plugin.rb            # Base plugin class
│   ├── router.rb            # Request router + circuit breaker
│   └── response.rb          # Response helpers
│
├── plugins/                 # Your plugins here!
│   ├── 00-maintenance.rb    # Management UI (/dylan)
│   ├── 10-checkip.rb        # Synology CheckIP emulation
│   ├── 20-monitor.rb        # Network monitor
│   ├── 30-pattern-redirect.rb  # Pattern-based redirects
│   ├── 50-simple-redirects.rb  # YAML redirects
│   └── 60-weather-demo.rb   # API example
│
├── config/
│   ├── crontab              # Cron schedule
│   └── redirects.yaml       # Simple redirect rules
│
├── scripts/
│   ├── monitor.sh           # Monitor cron job
│   └── start.sh             # Container startup
│
└── data/                    # Runtime data (generated)
    ├── monitor.html
    └── monitor_status.txt
```

### Development Workflow

```bash
# 1. Edit a plugin
vim plugins/70-my-plugin.rb

# 2. Restart container (hot reload not available)
docker restart dylan

# 3. Test the change
curl -I http://localhost:8080/your/path

# 4. Check logs
docker logs dylan -f

# 5. Debug
docker exec -it dylan /bin/sh
```

---

## Testing Plugins

### Manual Testing

```bash
# Test redirects
curl -I http://localhost:8080/g/ruby
# Expected: 302 redirect to Google

# Test JSON responses
curl http://localhost:8080/weather/Berlin
# Expected: JSON with weather data

# Test HTML responses
curl http://localhost:8080/dylan
# Expected: HTML management UI

# Test with verbose output
curl -v http://localhost:8080/your/path

# Test POST requests
curl -X POST -d '{"test":"data"}' \
  -H "Content-Type: application/json" \
  http://localhost:8080/api/endpoint
```

### Browser Testing

Open in browser for visual testing:
```
http://localhost:8080/dylan
http://localhost:8080/dylan/routes
http://localhost:8080/dylan/stats
```

### Performance Testing

Test async behavior with concurrent requests:

```bash
# Install Apache Bench (if not installed)
brew install httpd

# 1000 requests, 10 concurrent
ab -n 1000 -c 10 http://localhost:8080/dylan

# Check if slow requests don't block fast ones
curl http://localhost:8080/weather/Berlin &  # Slow (2s)
sleep 0.1
curl http://localhost:8080/g/test           # Should be instant!
```

### Circuit Breaker Testing

Test error handling with the chaos plugin:

```bash
# Enable chaos plugin
mv plugins/99-chaos-test.rb.disabled plugins/99-chaos-test.rb
docker restart dylan

# Trigger errors to test circuit breaker
for i in {1..5}; do curl http://localhost:8080/chaos/error; done

# Check stats to see circuit breaker activation
curl http://localhost:8080/dylan/stats
```

---

## Debugging

### View Logs

```bash
# Follow logs in real-time
docker logs dylan -f

# Last 100 lines
docker logs dylan --tail 100

# Search for errors
docker logs dylan | grep -i error

# Search for specific plugin
docker logs dylan | grep WikipediaPlugin

# Check circuit breaker activations
docker logs dylan | grep "CIRCUIT BREAKER"
```

### Debug Output in Plugins

Add debug output (appears in Docker logs):

```ruby
def call(host, path, request)
  puts "==> WikipediaPlugin called"
  puts "    Host: #{host}"
  puts "    Path: #{path}"
  puts "    Method: #{request.method}"

  # Your plugin logic
  Dylan::Response.redirect("https://wikipedia.org")
end
```

### Interactive Debugging

Access container shell:

```bash
# Enter container
docker exec -it dylan /bin/sh

# Check loaded plugins
ls -l /app/plugins/

# Test cron
crontab -l

# Check Ruby version
ruby --version
# Should show: ruby 4.0.1

# Check gems
bundle list

# Exit
exit
```

### Common Issues

**Plugin not loading:**
```bash
# Check syntax
docker exec dylan ruby -c /app/plugins/70-my-plugin.rb

# Check file permissions
docker exec dylan ls -la /app/plugins/

# Check logs for load errors
docker logs dylan | grep "FAILED to load"
```

**Pattern not matching:**
```ruby
# Add debug output
def call(host, path, request)
  puts "Pattern: #{pattern.inspect}"
  puts "Path: #{path.inspect}"
  puts "Match: #{pattern.match(path).inspect}"

  # ...
end
```

**Plugin timing out:**
```ruby
# Increase timeout for slow operations
class MyPlugin < Dylan::Plugin
  timeout(5.0)  # 5 seconds instead of default 500ms
end
```

---

## Best Practices

### Plugin Naming

Use numeric prefixes to control load order:

```
00-maintenance.rb     # Core functionality (always first)
10-*.rb              # Infrastructure (CheckIP, monitoring)
20-*.rb              # Network services
30-*.rb              # Pattern redirects
50-*.rb              # Simple redirects
60-*.rb              # Demos and experiments
70-*.rb              # Custom user plugins
```

### Error Handling

Dylan has built-in error handling, but you can add custom handling:

```ruby
def call(host, path, request)
  # Extract data
  match = path.match(pattern)
  return Dylan::Response.not_found unless match

  begin
    # Your logic here
    result = process_request(match[1])
    Dylan::Response.json(result)
  rescue StandardError => e
    puts "ERROR in MyPlugin: #{e.message}"
    puts e.backtrace.join("\n")
    Dylan::Response.error(500, "Internal Server Error")
  end
end
```

### Performance Tips

1. **Keep plugins fast**: Default 500ms timeout enforced
2. **Use async sleep**: For delays, use `Async::Task.current.sleep(n)`
3. **Set custom timeouts**: For external APIs, configure `timeout(seconds)`
4. **Avoid blocking**: Don't use regular `sleep` or blocking operations

```ruby
# BAD: Blocking operation (blocks all other requests!)
def call(host, path, request)
  sleep 5  # This blocks the entire fiber!
  Dylan::Response.text("Done")
end

# GOOD: Async sleep (yields to other requests)
def call(host, path, request)
  Async::Task.current.sleep(5)  # Other requests continue!
  Dylan::Response.text("Done")
end

# BEST: Quick response
def call(host, path, request)
  Dylan::Response.redirect("https://example.com")
end
```

### Robustness Features

Dylan 1.0 includes automatic robustness features:

1. **Circuit Breaker**: Plugins that error 5+ times are automatically disabled
2. **Timeout Protection**: Plugins that exceed their timeout are killed
3. **Safe Loading**: Syntax errors in plugins don't crash the server
4. **Error Recovery**: Plugin errors don't stop request processing

Monitor these features at `/dylan/stats`.

### Security

```ruby
# Sanitize user input
require 'uri'

def call(host, path, request)
  match = path.match(%r{^/search/(.+)$})
  query = URI.encode_www_form_component(match[1])

  Dylan::Response.redirect("https://google.com/search?q=#{query}")
end
```

---

## Advanced Topics

### Async HTTP Calls

Use async-http for non-blocking API calls:

```ruby
require 'async/http/internet'

class AsyncAPIPlugin < Dylan::Plugin
  pattern(%r{^/api/weather/(.+)$})
  timeout(5.0)  # External API needs more time

  def call(host, path, request)
    city = path.match(%r{^/api/weather/(.+)$})[1]

    # Make async HTTP request
    Async do
      internet = Async::HTTP::Internet.new
      response = internet.get("https://api.weather.com/v1/#{city}")
      data = response.read

      Dylan::Response.json(JSON.parse(data))
    ensure
      internet&.close
    end.wait
  end
end
```

### Database Access

Add database gems to Gemfile:

```ruby
# Gemfile
gem 'sqlite3'
gem 'sequel'
```

```ruby
# plugins/80-database.rb
require 'sequel'

class DatabasePlugin < Dylan::Plugin
  pattern(%r{^/db/users$})

  def call(host, path, request)
    db = Sequel.sqlite('/app/data/database.db')
    users = db[:users].all

    Dylan::Response.json(users)
  ensure
    db&.disconnect
  end
end
```

### Shared State

Store shared state in files or Redis:

```ruby
# Write to data directory (persisted)
File.write('/app/data/counter.txt', '0')

def call(host, path, request)
  count = File.read('/app/data/counter.txt').to_i
  count += 1
  File.write('/app/data/counter.txt', count.to_s)

  Dylan::Response.text("Visits: #{count}")
end
```

### Custom Cron Jobs

Add tasks to `config/crontab`:

```bash
# Update weather data every 10 minutes
*/10 * * * * /app/scripts/fetch_weather.sh > /proc/1/fd/1 2>&1

# Daily cleanup at 3 AM
0 3 * * * /app/scripts/cleanup.sh > /proc/1/fd/1 2>&1
```

Create script `scripts/fetch_weather.sh`:

```bash
#!/bin/sh
echo "==> Fetching weather data..."
curl -s "https://api.weather.com/..." > /app/data/weather.json
echo "==> Weather data updated"
```

Make executable:
```bash
chmod +x scripts/fetch_weather.sh
```

---

## Ruby 4.0 Features

Dylan 1.0 uses modern Ruby 4.0 features in the core:

### The `it` Parameter

```ruby
# Core code uses 'it' for cleaner syntax
plugin_files.each { puts "Loading: #{File.basename(it)}"; require it }

# In your plugins, use explicit parameters for clarity
@redirects.each do |redirect|
  # Process redirect
end
```

### Best Practices for Ruby 4.0

- Core framework code uses `it` for modern syntax
- Plugin code should stay explicit for readability
- User-facing APIs prioritize clarity over brevity

---

## Plugin Examples

### Simple Redirect

```ruby
class SimpleRedirectPlugin < Dylan::Plugin
  pattern(%r{^/home$})

  def call(host, path, request)
    Dylan::Response.redirect("https://example.com")
  end
end
```

### JSON API

```ruby
class StatusAPIPlugin < Dylan::Plugin
  pattern(%r{^/api/status$})

  def call(host, path, request)
    data = {
      status: "online",
      uptime: `uptime`.strip,
      timestamp: Time.now.iso8601
    }

    Dylan::Response.json(data)
  end
end
```

### HTML Dashboard

```ruby
class DashboardPlugin < Dylan::Plugin
  pattern(%r{^/dashboard$})

  def call(host, path, request)
    html = <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Dashboard</title>
          <style>
            body { font-family: sans-serif; margin: 40px; }
            h1 { color: #333; }
          </style>
        </head>
        <body>
          <h1>System Dashboard</h1>
          <p>Server: #{`hostname`.strip}</p>
          <p>Time: #{Time.now}</p>
        </body>
      </html>
    HTML

    Dylan::Response.html(html)
  end
end
```

---

## Version

**Dylan 1.0** - First release of Ruby 4.0 async HTTP router
