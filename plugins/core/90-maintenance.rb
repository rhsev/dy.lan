# frozen_string_literal: true

require 'uri'

# Maintenance Plugin — Dylan-Daten-API.
#
# Endpoints:
#   GET /dylan                 — Redirect zu /manage (Stage-UI)
#   GET /dylan/routes          — Registrierte Plugins (Markdown, ?format=json)
#   GET /dylan/test?path=/foo  — Route-Matching prüfen (Markdown, ?format=json)
#       /dylan/test/foo/bar    — alternative Path-Eingabe via URL-Suffix
#   GET /dylan/stats           — Server-Statistik (Markdown, ?format=json)
#   GET /dylan/slow[/<ms>]     — Async-Sleep für Performance-Tests (text)
#
# Reine Daten-Endpoints: Markdown-Text als Default für menschliche Konsumenten
# (Terminal, Stage's Output-Box), `?format=json` für Skripte. Reload lebt in
# einem eigenen Plugin (`96-reload.rb`) unter /reload. Die visuelle UI über
# diese Endpoints liefert `ManageStage` unter /manage.
#
# Security: In production, consider adding authentication or
# restricting access to local network only.

class MaintenancePlugin < Dylan::Plugin
  pattern(%r{^/dylan(/|$)})
  timeout(6.0)  # /dylan/slow erlaubt bis 5s async-sleep

  def initialize
    super
    @router = nil  # injected by server
  end

  # Inject router reference (called from server after initialization)
  def router=(router)
    @router = router
  end

  def call(host, path, request)
    base_path = path.split('?').first

    case base_path
    when '/dylan/routes'
      handle_routes(request)
    when %r{^/dylan/test}
      handle_test(request)
    when '/dylan/stats'
      handle_stats(request)
    when %r{^/dylan/slow(?:/(\d+))?$}
      handle_slow(Regexp.last_match(1)&.to_i)
    when '/dylan', '/dylan/'
      Dylan::Response.redirect('/manage')
    else
      Dylan::Response.not_found
    end
  end

  # GET /dylan/slow[/<ms>] — Async-Sleep für Performance-Tests.
  # Nicht-blockierend dank Fiber-Scheduler.
  def handle_slow(ms)
    ms = (ms || 2000).clamp(0, 5000)
    sleep(ms / 1000.0)
    Dylan::Response.text("slept #{ms}ms")
  end

  private

  # ── /dylan/routes ───────────────────────────────────────────────────────────

  def handle_routes(request)
    return error_no_router unless @router

    format = parse_query(request)['format']
    plugins = collect_plugins

    case format
    when 'json'
      # Explizite Hash-Klammern: Ruby 3+ würde ohne sie die Keys als Kwargs
      # interpretieren und json(data, status:) sich beklagen.
      Dylan::Response.json({ total: plugins.count, plugins: plugins })
    else
      Dylan::Response.text(render_routes_markdown(plugins))
    end
  end

  def render_routes_markdown(plugins)
    # Spalten-Alignment für Monospace-Konsumenten (Stage Output-Box, curl).
    name_width = plugins.map { |p| p[:name].length }.max || 0
    rows = plugins.map { |p|
      "- #{p[:priority]}  #{p[:name].ljust(name_width)}  #{p[:pattern]}"
    }.join("\n")
    <<~MD
      ## Registered Routes

      #{rows}

      Total: #{plugins.count} plugin(s). First match wins (lower priority = checked first).
    MD
  end

  # Liste der registrierten Plugins, sortiert nach Priorität.
  # Priority kommt aus dem Filename (z.B. "30-pattern-redirect.rb" → "30");
  # bei Klassen ohne Datei-Match fallback auf Load-Order-Index.
  def collect_plugins
    priority_map = build_priority_map
    plugins = @router.plugins.map.with_index do |plugin, index|
      class_name = plugin.class.name
      priority = priority_map[class_name] || format('%02d', index)
      { priority: priority, name: class_name, pattern: plugin.pattern.inspect }
    end
    plugins.sort_by { |p| p[:priority].to_i }
  end

  def build_priority_map
    map = {}
    return map unless @router.plugin_dir && Dir.exist?(@router.plugin_dir)

    Dir.glob(File.join(@router.plugin_dir, '**', '*.rb')).each do |file|
      basename = File.basename(file)
      next unless basename =~ /^(\d+)-/
      priority = Regexp.last_match(1)

      File.read(file).scan(/^class\s+(\w+(?:Plugin|Stage))\s+</).each do |match|
        map[match[0]] = priority
      end
    end
    map
  end

  # ── /dylan/test ─────────────────────────────────────────────────────────────

  def handle_test(request)
    return error_no_router unless @router

    query  = parse_query(request)
    format = query['format']

    # Path kommt entweder als ?path=… oder als URL-Suffix /dylan/test/<path>.
    # Letzteres ist freundlicher für Stage's Input-Buttons (die ans Ende der
    # URL anhängen) und für curl-Aufrufe ohne Query-Escaping.
    test_path = query['path']
    if !test_path
      suffix = request.path.split('?', 2)[0].sub(%r{^/dylan/test/?}, '')
      unless suffix.empty?
        decoded = URI.decode_www_form_component(suffix)
        # Routes in Dylan beginnen immer mit / — der Suffix-Extract verliert es.
        test_path = decoded.start_with?('/') ? decoded : "/#{decoded}"
      end
    end
    test_path ||= '/'

    matched = @router.plugins.find { |p| p.match?('', test_path) }

    result = if matched
      { matched: true,  path: test_path, plugin: matched.class.name, pattern: matched.pattern.inspect }
    else
      { matched: false, path: test_path, message: 'No plugin matches this path (would return 404)' }
    end

    case format
    when 'json'
      Dylan::Response.json(result)
    else
      Dylan::Response.text(render_test_markdown(result))
    end
  end

  def render_test_markdown(result)
    if result[:matched]
      <<~MD
        ## Route Tester

        Path: #{result[:path]}

        ### ✅ Match

        - Plugin:  #{result[:plugin]}
        - Pattern: #{result[:pattern]}

        Usage: GET /dylan/test?path=/foo/bar  or  GET /dylan/test/foo/bar
      MD
    else
      <<~MD
        ## Route Tester

        Path: #{result[:path]}

        ### ❌ No match

        This path would return 404 Not Found.

        Usage: GET /dylan/test?path=/foo/bar  or  GET /dylan/test/foo/bar
      MD
    end
  end

  # ── /dylan/stats ────────────────────────────────────────────────────────────

  def handle_stats(request)
    return error_no_router unless @router

    format = parse_query(request)['format']
    stats  = collect_stats

    case format
    when 'json'
      Dylan::Response.json(stats)
    else
      Dylan::Response.text(render_stats_markdown(stats))
    end
  end

  def collect_stats
    uptime = @router.uptime
    {
      uptime_seconds:     uptime.round(2),
      uptime_human:       format_duration(uptime),
      total_requests:     @router.stats[:total_requests],
      requests_by_plugin: @router.stats[:requests_by_plugin],
      errors_by_plugin:   @router.stats[:errors_by_plugin],
      disabled_plugins:   @router.disabled_plugins.to_a,
      plugin_count:       @router.route_count,
      started_at:         @router.stats[:started_at].iso8601
    }
  end

  def render_stats_markdown(stats)
    out = +"## Server Statistics\n\n"

    unless stats[:disabled_plugins].empty?
      out << "⚠️ Circuit Breaker active — disabled plugins: "
      out << stats[:disabled_plugins].join(', ')
      out << "\n\n"
    end

    out << "- Uptime:             #{stats[:uptime_human]}\n"
    out << "- Total requests:     #{stats[:total_requests]}\n"
    out << "- Registered plugins: #{stats[:plugin_count]}\n\n"

    if stats[:requests_by_plugin].empty?
      out << "(no requests yet)\n"
    else
      out << "## Requests by plugin\n\n"
      name_width = stats[:requests_by_plugin].keys.map(&:length).max
      stats[:requests_by_plugin].each do |plugin, count|
        disabled    = stats[:disabled_plugins].include?(plugin)
        error_count = stats[:errors_by_plugin][plugin] || 0
        tags = []
        tags << "DISABLED"               if disabled
        tags << "#{error_count} errors"  if error_count > 0
        suffix = tags.empty? ? '' : "  — #{tags.join(', ')}"
        out << "- #{plugin.ljust(name_width)}  #{count}#{suffix}\n"
      end
    end

    out << "\nStarted: #{stats[:started_at]}\n"
    out
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  def parse_query(request)
    query_string = request.path.split('?', 2)[1] || ''
    query_string.split('&').each_with_object({}) do |pair, hash|
      key, value = pair.split('=', 2)
      hash[key] = value if key
    end
  end

  def format_duration(seconds)
    days    = (seconds / 86400).to_i
    hours   = ((seconds % 86400) / 3600).to_i
    minutes = ((seconds % 3600) / 60).to_i
    secs    = (seconds % 60).to_i

    parts = []
    parts << "#{days}d"    if days > 0
    parts << "#{hours}h"   if hours > 0
    parts << "#{minutes}m" if minutes > 0
    parts << "#{secs}s"
    parts.join(' ')
  end

  def error_no_router
    Dylan::Response.error(500, 'Router not available. Plugin not properly initialized.')
  end
end
