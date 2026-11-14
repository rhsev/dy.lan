# Dylan: Writing Plugins

Complete guide for developing, testing, and extending Dylan via plugins.

---

## Table of Contents

1. [Plugin Development](#plugin-development)
2. [Plugin Folder Structure](#plugin-folder-structure)
3. [Built-in Libraries](#built-in-libraries)
4. [Plugin Configuration (DSL)](#plugin-configuration-dsl)
5. [Stage: Multi-Instance UI Plugin](#multi-instance-plugins-stagebase-pattern)
6. [Development Environment](#development-environment)
7. [Testing Plugins](#testing-plugins)
8. [Debugging](#debugging)
9. [Best Practices](#best-practices)
10. [Advanced Topics](#advanced-topics)

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

Create `plugins/extra/70-wikipedia.rb`:

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
    # Make external API call; plain sleep/IO yields to other requests
    # (fiber scheduler), so this stands in for a slow backend
    sleep(2)

    Dylan::Response.json({ status: "ok" })
  end
end
```

### Plugin Lifecycle

1. **Load**: Plugins are loaded by basename across all plugin folders
   - `00-*.rb` loads before `50-*.rb`
   - Use numeric prefixes to control order

2. **Registration**: `Dylan::Plugin.inherited` auto-registers plugins

3. **Routing**: Router checks patterns in load order
   - First matching pattern wins
   - Once a plugin returns a response, routing stops
   - Failed plugins don't stop routing (error handling continues to next plugin)
   - If no later plugin answers, the first failure decides the status:
     500 for an exception, 504 for a timeout, 503 while the circuit breaker
     holds the plugin off. Only a path no plugin matches is a 404.

4. **Reload**: `/reload` ends the Ruby process; Docker's restart policy
   brings the container back within seconds, with every plugin, `lib/` and
   `server.rb` loaded fresh
   ```bash
   curl http://localhost:8080/reload
   # same effect from the host:
   docker restart dylan
   ```

---

## Plugin Folder Structure

Plugins live in four subdirectories of `plugins/`. The loader scans
**all of them recursively** and sorts by **basename** (so the numeric prefix
controls priority across folders, not within them).

```
plugins/
├── core/      # functionally essential, shipped with Dylan
│   ├── 00-host-redirects.rb
│   ├── 05-favicon.rb
│   ├── 35-milan-connect.rb
│   ├── 50-simple-redirects.rb
│   ├── 55-stage.rb          # StageBase + ManageStage instance
│   ├── 60-jobs.rb           # /jobs/check: ntfy for finished Milan jobs (cron)
│   ├── 90-maintenance.rb
│   ├── 91-manage.rb         # Stage instance at /manage
│   ├── 95-whoami.rb         # milan identity check (?name=, whoami_also_from)
│   └── 96-reload.rb         # /reload: restart the server process
├── extra/     # public, ships with Dylan (demos, anonymized variants)
│   ├── 10-checkip.rb.disabled
│   ├── 30-pattern-redirect.rb.disabled
│   ├── 60-weather-demo.rb.disabled
│   ├── 65-monitor.rb
│   ├── 66-probe.rb
│   └── 99-chaos-test.rb.disabled   # rename to enable (see Testing)
├── custom/    # your private plugins: gitignored, deployed everywhere
│   └── 56-my-stage.rb       # example: private Stage instance
└── local/     # belongs to ONE deployment: never travels, usually empty
```

**Where should your plugin go?**

- **`core/`**: only for plugins that are essential to Dylan's URL-routing
  feature set (proxy, redirects, dashboard). Rarely the right place for
  user-written plugins.
- **`extra/`**: public examples, generic helpers, anything you'd be happy
  to publish on GitHub.
- **`custom/`**: anything that contains inline secrets, personal config,
  or domain-specific behavior. Gitignored by default. **This is where a
  private plugin belongs**; it is still written at the source and deployed
  to every installation.
- **`local/`**: for a plugin you write **on the running installation**
  rather than at the source. Normally empty, and normally the wrong answer:
  work at the source and let it deploy.

A sync only knows what the source has, so a deployment that mirrors
deletions (with twin: `Delete: true`) removes a plugin that was created on
the target, without asking. If you do edit where Dylan runs, put the file in
`local/` and exclude that folder from the sync (with twin: `Own: local` on
the `plugins` job, which protects it from overwrite and from `--delete`).
For a plugin that only holds secrets, `custom/` is enough: write it at the
source and deploy it like everything else.

**Convention**: If a plugin has its config in YAML (e.g. `redirects.yaml`),
it can stay generic in `extra/`. If a plugin hardcodes domain-specific
behavior inside Ruby, prefer `custom/` and (optionally) ship an anonymized
variant in `extra/` for documentation.

---

## Built-in Libraries

Dylan ships several reusable libraries in `lib/` that plugins can compose:

| Lib | Purpose |
|---|---|
| `Dylan::Response` | HTTP response builders (`text`, `html`, `json`, `redirect`, `error`), and `deferred`, `stream`, `sse_stream` for work that takes longer than the plugin timeout. |
| `Dylan::HttpPool` | Reusable `Async::HTTP::Client` pool. Single source for HTTP connection caching. |
| `Dylan::Milan` | Milan agent registry + cached HTTP clients. `get!`, `post!`, `stream`, `proxy_sse`, error-mapping `rescued` helper. Only relevant when you talk to a Milan companion server. See [Talking to Milan](#talking-to-milan). |
| `Dylan::MilanDouble` | Milan for tests: canned answers and a record of the calls. See [Testing a plugin that talks to Milan](#testing-a-plugin-that-talks-to-milan). |
| `Dylan::StaticAssets` | Static file server with ETag + mtime-based hot-reload. For plugins that ship HTML/CSS/JS bundles. |
| `Dylan::Ansi` | ANSI → HTML for terminal output (`Dylan::Ansi.to_html`). SGR colours, bold, `\r` line rewrites; everything else stripped. |

Every plugin also inherits two small helpers from `Dylan::Plugin`:
`query_params(request)` returns the query string as a Hash, and
`within(seconds) { ... }` puts a time limit on one step inside `call`.

### Talking to Milan

`get!` and `post!` raise when the agent answers with an error status, for
example 422 for a failed script or 404 for an unknown one. Inside `rescued`
every failure becomes the fitting response: the agent's own status and message,
503 for an agent that is unreachable or not configured, 504 when the plugin's
timeout ran out.

```ruby
class DiskPlugin < Dylan::Plugin
  pattern(%r{^/disk$})
  timeout(5)

  def call(host, path, request)
    Dylan::Milan.rescued('mini', label: 'Disk') do
      Dylan::Response.text(Dylan::Milan.get!('mini', '/disk-usage').body)
    end
  end
end
```

`get` and `post` without the `!` return the answer whatever its status. Use
them when the status itself is what you want to read or pass on.

Asking several agents: give each one its own limit with `within`, so that one
absent agent does not use up the time of the others, and ask them at once:

```ruby
def call(host, path, request)
  lines = Dylan::Milan.agents.keys.map { |name| Async { line_for(name) } }.map(&:wait)
  Dylan::Response.text(lines.join("\n"))
end

def line_for(name)
  "#{name}: #{within(2) { Dylan::Milan.get!(name, '/uptime').body.strip }}"
rescue Async::TimeoutError, Dylan::Milan::UnreachableError
  "#{name}: no answer"
end
```

A script that runs longer than the timeout goes through
[`Response.deferred` or `Response.sse_stream`](#work-that-outlives-the-timeout).
To forward an agent's stream as it is, with its status and content type, use
`Dylan::Milan.pass_stream(agent, path)`. `Dylan::Milan.request` is the general
call for the methods beyond GET and POST (`method:`, `body:`, `headers:`).

**Example using Dylan::HttpPool** (reverse-proxy a backend):
```ruby
class ProxyPlugin < Dylan::Plugin
  pattern(%r{^/wiki/})

  def initialize
    super
    @pool = Dylan::HttpPool.new
  end

  def call(host, path, request)
    client = @pool.for('https://en.wikipedia.org')
    # ... use client.get(path) etc.
  end
end
```

**Example using Dylan::StaticAssets** (serve a bundled frontend):
```ruby
class MyDashboard < Dylan::Plugin
  pattern(%r{^/my(/|$)})
  ASSETS_DIR  = File.join(__dir__, 'my')          # plugins/.../my/
  ASSET_TYPES = { 'style.css' => 'text/css; charset=UTF-8',
                  'app.js'    => 'application/javascript; charset=UTF-8' }.freeze

  def initialize
    super
    @assets = Dylan::StaticAssets.new(dir: ASSETS_DIR, types: ASSET_TYPES)
  end

  def call(host, path, request)
    case path
    when %r{^/my/assets/([\w.-]+)$}
      @assets.serve(Regexp.last_match(1), request)
    else
      Dylan::Response.html(File.read(File.join(ASSETS_DIR, 'index.html')))
    end
  end
end
```

`Dylan::StaticAssets` handles browser-side ETag caching (`304 Not Modified`
when unchanged) and a server-side memory cache that invalidates on file
mtime change, so edits to `style.css`/`app.js` are visible on the next browser
request without a container restart.

See `plugins/core/90-maintenance.rb` and `plugins/extra/65-monitor.rb` for
working examples in the codebase.

---

## Plugin Configuration (DSL)

For plugins that read config from a YAML file in `config/`, use the
built-in `config_file` DSL. It provides hot-reload with throttled mtime
checks and an optional `on_config_reload` callback.

```ruby
class MyRedirectsPlugin < Dylan::Plugin
  pattern(/.^/)                           # match? wird überschrieben
  config_file 'my-redirects.yaml'         # read config/my-redirects.yaml
  config_section 'redirects'              # optional: only YAML['redirects']
  config_check_interval 10                # optional: stat throttle (default 5s)

  def initialize
    super
    @rules = []
    config                                # initial load triggers on_config_reload
  end

  def match?(host, path)
    config                                # ggf. hot-reload
    @rules.any? { |r| path.match?(r[:pattern]) }
  end

  def call(host, path, request)
    # ... use @rules
  end

  protected

  def on_config_reload(data)
    # called once on initial load and on every actual mtime change
    @rules = (data['redirects'] || []).map { |r| { pattern: Regexp.new(r['pattern']) } }
    puts "🔄 Reloaded #{@rules.count} rules"
  end
end
```

**Other class-level DSLs:**

- `abstract`: marks this class as a non-routing base. Used when several
  concrete plugins share a base class (see Stage below).
- `pattern(regex)`: URL match. Set once per concrete class.
- `timeout(seconds)`: per-plugin request timeout (default 0.5s).

### Multi-Instance Plugins (StageBase pattern)

When the same logic should run at multiple URL prefixes, each with its own
config file, define an abstract base class and small concrete subclasses:

```ruby
# plugins/core/55-stage.rb
class StageBase < Dylan::Plugin
  abstract          # do not route directly
  timeout(5.0)

  class << self
    def url_prefix(prefix = nil)
      @url_prefix = prefix if prefix
      @url_prefix
    end
  end

  def call(host, path, request)
    # all logic here, uses self.class.url_prefix and config
  end
end

# plugins/core/91-manage.rb
class ManageStage < StageBase
  pattern         %r{^/manage(/|\?|$)}
  url_prefix      '/manage'
  config_file     'manage.yaml'
  config_section  'stage'
end
```

Private instances go in `plugins/custom/` with a priority between 55 and 90:

```ruby
# plugins/custom/56-my-stage.rb
class MyStage < StageBase
  pattern         %r{^/stage(/|\?|$)}
  url_prefix      '/stage'
  config_file     'stage.yaml'
  config_section  'stage'
end
```

Each instance gets its own YAML config. `StageBase` is shipped in `core/`,
private instances stay gitignored in `custom/`.

### Stage YAML config

```yaml
# config/stage.yaml
stage:
  title: "My Stage"
  sheets_agent: "mini"       # Milan agent for cheat sheets

  # Link grid (default landing view)
  links:
    - title: "Tools"
      items:
        - { label: "Dockhand", url: "http://192.168.1.33:3000", icon: "🚢" }
        - { label: "Router",   url: "http://192.168.1.1",       icon: "mdi:router" }

  # Sidebar buttons
  sections:
    - title: "Actions"
      buttons:
        - id: greet
          label: "👋 Greet"
          type: stream
          url: "/mini/stream/greet"

        - id: table
          label: "📋 Table"
          type: action
          url: "/dylan/table"
          format: nowrap      # preserves column alignment, horizontal scroll
```

**Button types:** `action`, `stream`, `input`, `notes`, `jobs`, `widget`, `panel`

**Icons:** emoji string or `mdi:<name>` (SVG from `plugins/core/stage/icons/`)

### Panels (`type: panel`)

A panel button does not run anything: it switches the main area to a view
that Dylan renders on the server. `action`, `stream` and `input` stay
actions with output; a panel is a place.

```yaml
sections:
  - title: "Views"
    buttons:
      - id: links
        type: panel
        panel: links
        label: "Links"
        default: true       # the view the page opens with

      - id: board
        type: panel
        panel: widget
        label: "Board"
        refresh: 3

      - id: cheaters
        type: panel
        panel: notes
        source: cheaters    # a note source of the Milan agent
```

| `panel` | Shows | `source` / `src` |
|---|---|---|
| `links` | the link grid | key under `links:` when it is a map of lists (default `default`) |
| `widget` | the widget tiles of the instance's `agent` | |
| `jobs` | background jobs across all agents | |
| `notes` | a note source rendered by Milan | note source id (default: the button `id`) |
| `frame` | a page of this dylan in a frame, e.g. the monitor | `src`: a path, e.g. `/monitor` |
| `album` | an album page via Milan, in a frame | binder name |

Each panel has its own URL, `/<instance>/panel/<id>` (e.g. `/stage/panel/board`):
called directly it returns the full page with that panel open, fetched by
Stage it returns only the fragment.

### Widget tiles (`type: widget`)

A widget entry is not a button: it is a passive state tile. Scripts push their
state to a Milan agent's widget inbox (`POST /widget/<target>`), and the
instance shows all targets as a grid, with one `GET /<agent>/widgets` per refresh,
no matter how many tiles. An instance that has tiles renders them as its home
view and polls; the sidebar keeps only the real buttons.

```yaml
# config/board.yaml
board:
  title: "Board"
  agent: "mini"         # Milan agent whose inbox is read
  refresh: 3            # seconds between polls (default 3)

  sections:
    - title: "Läuft"
      buttons:
        - id: copy
          type: widget
          target: copy        # defaults to id
          label: "Backup"     # falls back to the pushed title, then the target
          icon: download
          doc: "https://…"    # optional ⓘ in the tile head

    - title: "Sonstiges"
      discover: true          # every target no configured tile claims
```

- **ANSI** in the pushed text is rendered by `Dylan::Ansi` (`lib/ansi.rb`);
  256-colour and truecolor sequences are stripped rather than guessed at.
- **`ttl`** comes from the push, not the YAML: with one, the tile greys out
  when it expires (something that should be running is not); without one it
  is a slow state and just shows the clock time of the last push.
- The reply carries an **ETag** over the tile states, so the usual answer to a
  poll is `304`: no render, no transfer. Expiry is part of the digest.
- **`doc`** adds a small ⓘ next to the clock, linking to whatever explains the
  tile. It is read from the YAML and never from the push: a tile shows a state,
  and where that state is explained is a property of the display. Taken from
  the push, any producer could hang links in the interface. Only `http(s)://`
  and site-relative URLs render; anything else is dropped. External hosts open
  in a new tab, the same rule the link cards follow.

### Frontend rules (`plugins/core/stage/`)

The Stage is meant to open on whatever is lying around, old iPads included.
That sets a floor of **Safari 10.1 / iOS 10.3**, verified on an iPad mini 2.
`fetch`, `async`/`await` and CSS Grid are what hold it there; two rules keep
it from creeping upwards.

**No syntax newer than ES2017 in `app.js`.** Optional chaining and `??` are
*parse* errors on older engines, so one of them discards the entire file,
not just its own line. The symptom is not a blank page but a rendered shell
with empty panels, because Dylan renders the frame server-side and only the
panel content comes from the script. Check before committing:

```bash
npx acorn --ecma2017 --silent plugins/core/stage/app.js
```

**No `gap` in flex containers.** Safari before 14.1 supports it in grid only,
so flex children sit flush. Grid `gap` is fine and is used in `.link-grid` and
`.tile-grid`. `@supports (gap: 1px)` does not help: it answers yes for the
grid support and cannot tell the two apart.

When spacing a flex container, mind who owns the margin:

- `> * + *` carries the specificity of a **single class** and loses against any
  child that sets the same margin itself. Check the children first.
- Where a child has its own margin, give it the spacing instead of the
  container. `.link-grid-title` holds both its distances for that reason.
- Where the first child can be `display: none` (as `header`'s burger is above
  700px), a sibling selector invents a margin in front of the second one.
  `header` keeps `gap` and simply loses its spacing on old Safari.
- `.output-label` starts with a text node, so it needs `> *`, not `> * + *`.

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

### Work that outlives the timeout

The router cuts `call` off when the plugin's timeout runs out (0.5 s unless
the plugin sets its own). Work that can take longer, such as a script on a
Milan agent or a slow backend, does not belong inside `call`. Three helpers
return the response at once and produce its content afterwards, outside the
timeout. They close the body correctly and deliver a failure to the reader.

One piece of content, produced later. The block returns it:

```ruby
def call(host, path, request)
  Dylan::Response.deferred(on_error: ->(e) { "<p>#{CGI.escape_html(e.message)}</p>" }) do
    Dylan::Milan.get!('mini', '/album/urlaub').body
  end
end
```

Content in pieces. The block writes to the body, and the response ends when
the block ends:

```ruby
def call(host, path, request)
  Dylan::Response.stream(content_type: 'text/plain; charset=UTF-8') do |body|
    Dylan::Milan.stream('mini', '/stream/backup') { |chunk| body.write(chunk) }
  end
end
```

Server-Sent Events. A failure goes out as a `stream_error` event followed by
`done`, the two events the Stage pad understands:

```ruby
def call(host, path, request)
  Dylan::Response.sse_stream do |body|
    3.times do |i|
      body.write("data: line #{i}\n\n")
      sleep(1)
    end
    body.write("event: done\ndata: \n\n")
  end
end
```

The status of such a response is 200 before the content exists. A failure
therefore arrives as content (`on_error`) and not as a 502.

`Dylan::Response.sse` is the manual form: it yields the body, and the plugin
starts the `Async` task itself and ends it with `body.close_write`. Do not use
`body.close` there. It discards what the reader has not fetched yet, which is
the last event written.

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

# Match /search with or without query params. Dylan's path includes the
# query string, so ^/search$ would miss /search?q=ruby
pattern(%r{^/search(\?|$)})

# Match host (for multi-tenant setups): match? tries host, then path
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

`query_params(request)` returns the query string as a Hash. Values come back
as sent, without URL decoding:

```ruby
def call(host, path, request)
  format = query_params(request)['format']   # /things?format=json
  # ...
end
```

To get decoded values, parse the query string yourself:

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
   rbenv install 4.0.7
   rbenv local 4.0.7
   ```

2. **Install dependencies**
   ```bash
   cd dy.lan
   bundle install
   ```

3. **Run Dylan locally** (without Docker)
   ```bash
   bundle exec ruby server.rb
   ```

4. **Or use Docker** (recommended)
   ```bash
   docker compose up
   ```

### File Structure

```
dy.lan/
├── server.rb                       # Main server entry point
├── Gemfile                         # Ruby dependencies
├── test_performance.rb             # Latency, concurrency and load check
│
├── lib/                            # Reusable libraries
│   ├── plugin.rb                   # Base plugin class + DSLs
│   ├── router.rb                   # Request router + circuit breaker
│   ├── response.rb                 # Response helpers (text/html/json/sse/error)
│   ├── http_pool.rb                # Async::HTTP::Client pool
│   ├── milan.rb                    # Milan companion-server client
│   ├── ansi.rb                     # ANSI → HTML for terminal output
│   └── static_assets.rb            # Static file server with ETag caching
│
├── plugins/                        # Plugin folders (recursive scan)
│   ├── core/                       # essential Dylan features
│   │   ├── 00-host-redirects.rb    # Reverse proxy + host-based redirects
│   │   ├── 05-favicon.rb           # SVG favicon
│   │   ├── 35-milan-connect.rb     # /<agent>/<path>: calls, POST bodies and streams to Milan
│   │   ├── 50-simple-redirects.rb  # YAML-driven redirects
│   │   ├── 55-stage.rb             # StageBase + all Stage logic
│   │   ├── 60-jobs.rb              # /jobs/check: ntfy for finished Milan jobs
│   │   ├── 90-maintenance.rb       # Dashboard, /dylan/*
│   │   ├── 91-manage.rb            # Stage instance at /manage
│   │   ├── 95-whoami.rb            # Milan identity check
│   │   ├── 96-reload.rb            # /reload: restart the server process
│   │   └── stage/                  # Stage frontend assets
│   │       ├── index.html
│   │       ├── app.js
│   │       ├── style.css
│   │       ├── MonaspaceArgon-Variable.woff2
│   │       └── icons/              # MDI SVG icons
│   ├── extra/                      # Demos & public examples
│   │   ├── 10-checkip.rb.disabled           # Synology CheckIP emulation
│   │   ├── 30-pattern-redirect.rb.disabled  # Pattern-redirect demo
│   │   ├── 60-weather-demo.rb.disabled      # External API demo
│   │   ├── 65-monitor.rb                    # Network-monitor display
│   │   ├── 66-probe.rb                      # Polls the Milan agents
│   │   └── 99-chaos-test.rb.disabled        # Misbehaves on purpose
│   ├── custom/                     # Your private plugins (gitignored)
│   └── local/                      # Plugins of one deployment (gitignored)
│
├── config/
│   ├── crontab                     # Cron schedule (container-side)
│   ├── manage.yaml                 # Stage config for /manage
│   ├── milan.yaml                  # Milan agent registry (+ whoami_also_from)
│   └── redirects.yaml              # Simple redirects
│
├── scripts/
│   ├── monitor.sh                  # Monitor cron job
│   ├── smoke.sh                    # Smoke tests for live instance
│   └── start.sh                    # Container startup
│
├── test/                           # minitest, see Testing Plugins
│
└── data/                           # Runtime data (gitignored, generated)
```

### Development Workflow

```bash
# 1. Edit a plugin
vim plugins/extra/70-my-plugin.rb

# 2. Restart the server (or: docker restart dylan)
curl http://localhost:8080/reload

# 3. Test the change
curl -I http://localhost:8080/your/path

# 4. Check logs
docker logs dylan -f

# 5. Debug
docker exec -it dylan /bin/sh
```

---

## Testing Plugins

### Unit tests

Logic that does not need a running server is tested with minitest. That
needs no server or container, only the gems from the `Gemfile` (`bundle install`):

```bash
ruby test/ansi_test.rb          # ANSI → HTML renderer
ruby test/helpers_test.rb       # deferred/stream responses, get!/post!, within, the Milan double
ruby test/jobs_test.rb          # job notifications: acknowledged only after the message is out
ruby test/milan_connect_test.rb # /<agent>/<path>: methods, status, streams
ruby test/panel_test.rb         # Stage panels, link grid, widget tiles (Milan stubbed)
ruby test/router_test.rb        # routing, failure statuses, circuit breaker
ruby test/sse_stream_test.rb    # SSE proxy error path reaches the browser
ruby test/stream_frame_test.rb  # iframe routes outside the plugin timeout
ruby test/whoami_test.rb        # milan identity check
```

Without a local Ruby 4, run them in the image:

```bash
docker compose run --rm --no-deps -v "$PWD/test:/app/test:ro" dylan \
  sh -c 'for f in test/*_test.rb; do ruby "$f"; done'
```

### Testing a plugin that talks to Milan

`Dylan::MilanDouble` stands in for Milan. The test says what Milan answers and
reads back what the plugin asked for. No agent and no network are involved.

```ruby
require 'minitest/autorun'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/milan_double'
require_relative '../plugins/custom/70-disk'

class DiskTest < Minitest::Test
  def setup    = @milan = Dylan::MilanDouble.use
  def teardown = Dylan::MilanDouble.reset

  def test_passes_the_agents_error_on
    @milan.respond(path: '/disk-usage', status: 422, body: 'df failed')
    response = DiskPlugin.new.call('dy.lan', '/disk', nil)

    assert_equal 422, response.status
    assert_equal [[:get, 'mini', '/disk-usage']], @milan.calls
  end
end
```

`respond` takes `path:` (a String or a Regexp), `agent:`, `status:`, `body:`
(anything that is not a String is sent as JSON), `error:` (an exception to
raise), `delay:` (seconds) and `chunks:` (for `stream`). The rule added last
wins. A request that no rule matches gets an empty 200. The default agents are
`mini` and `book`; `MilanDouble.use(agents: { ... })` sets others.

Use the double and do not prepend a stub of your own to `Dylan::Milan`. CI runs
all test files in one process, and stubs from different files get in each
other's way there.

### Manual Testing

```bash
# Test redirects: redirects.yaml only answers for its `domains:`
curl -I -H 'Host: dy.lan' http://localhost:8080/g/ruby
# Expected: 302 redirect to Google

# Test JSON responses
curl 'http://localhost:8080/dylan/stats?format=json'
# Expected: JSON with server statistics

# Test HTML responses
curl http://localhost:8080/manage
# Expected: HTML management UI (/dylan redirects here)

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

Touching `plugins/core/stage/` also means staying inside the browser floor:
see [Frontend rules](#frontend-rules-pluginscorestage).

### Performance Testing

`test_performance.rb` checks real routes against their expected status,
runs `/dylan/slow/2000` next to fast requests (they must not wait for it)
and adds a short keep-alive load run. It exits 1 on any unexpected status:

```bash
DYLAN_HOST=localhost DYLAN_PORT=8080 ruby test_performance.rb
DYLAN_HOST=dy.lan DYLAN_PORT=80 DYLAN_LOAD_SECONDS=0 ruby test_performance.rb  # live, no load
```

The Ruby client tops out early; for throughput numbers use wrk:

```bash
wrk -t2 -c20 -d10s -H 'Host: dy.lan' http://localhost:8080/dylan/stats
```

### Circuit Breaker Testing

Test error handling with the chaos plugin:

```bash
# Enable chaos plugin
mv plugins/extra/99-chaos-test.rb.disabled plugins/extra/99-chaos-test.rb
docker restart dylan

# Trigger errors to test circuit breaker; each answers 500
for i in {1..5}; do curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/chaos/error; done

# Now disabled for 5 minutes: 503
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/chaos/error

# Check stats to see circuit breaker activation
curl 'http://localhost:8080/dylan/stats?format=json'
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
# Should show: ruby 4.0.x

# Check gems
bundle list

# Exit
exit
```

### Common Issues

**Plugin not loading:**
```bash
# Check syntax
docker exec dylan ruby -c /app/plugins/extra/70-my-plugin.rb

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
00-*.rb              # Host-based routing and proxy (sees every request first)
05-*.rb              # Favicon
10-*.rb              # Infrastructure (CheckIP)
30-*.rb              # Pattern redirects
35-*.rb              # Milan forwarding (/<agent>/…)
50-*.rb              # Simple redirects (YAML)
55-59-*.rb           # Stage instances
60-*.rb              # Job notifications (/jobs/check); demos and experiments
65-69-*.rb           # Monitoring (monitor, probe)
70-*.rb              # Custom user plugins
90-99-*.rb           # Maintenance, /manage, whoami, reload, chaos test
```

### Error Handling

If `call` raises, the router logs the error and answers 500 (504 on a
timeout) unless a later plugin answers the path. Catch it yourself only when
the plugin has something better to say:

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
2. **Set custom timeouts**: For external APIs, configure `timeout(seconds)`
3. **Waiting is fine, computing is not**: Ruby 4 runs Dylan under a fiber
   scheduler, so `sleep`, socket and HTTP I/O yield to other requests. What
   blocks everyone is CPU work and C extensions that bypass the scheduler.
   (`Async::Task#sleep` is deprecated; plain `sleep` does the same.)

```ruby
# BAD: CPU-bound loop (no other request is served meanwhile)
def call(host, path, request)
  total = (1..200_000_000).sum { it * it }
  Dylan::Response.text(total.to_s)
end

# FINE: waiting yields (other requests continue, see /dylan/slow)
def call(host, path, request)
  sleep 2
  Dylan::Response.text("Done")
end

# BEST: Quick response
def call(host, path, request)
  Dylan::Response.redirect("https://example.com")
end
```

### Robustness Features

Dylan includes automatic robustness features:

1. **Circuit Breaker**: 5 errors within 60 s disable a plugin for 5 minutes;
   meanwhile its paths answer 503, then it is re-enabled automatically
2. **Timeout Protection**: Plugins that exceed their timeout are cancelled (504)
3. **Safe Loading**: Syntax errors in plugins don't crash the server
4. **Error Recovery**: Plugin errors don't stop request processing; a failed
   path answers 500, not a misleading 404

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

# Note: prefer Dylan::HttpPool over Async::HTTP::Internet for requests to the
# same host: the pool reuses connections across requests instead of opening
# a new one each time. Async::HTTP::Internet is fine for one-off calls to
# varying external hosts.
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
# plugins/custom/80-database.rb
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

Dylan uses modern Ruby 4.0 features in the core:

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

What changed in each version is in the
[release notes](https://github.com/rhsev/dy.lan/releases).
