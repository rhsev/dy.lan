# frozen_string_literal: true

# Maintenance Plugin — Dylan-Server-Verwaltung und Diagnose.
#
# Endpoints:
#   GET /dylan                 — Dashboard
#   GET /dylan/routes          — Registrierte Plugins
#   GET /dylan/test?path=/foo  — Route-Matching prüfen
#   GET /dylan/stats           — Server-Statistik (Uptime, Request-Counts)
#   GET /dylan/reload          — Server-Restart (exit(0) + Docker-Restart-Policy)
#   GET /dylan/slow[/<ms>]     — Async-Sleep für Performance-Tests
#   GET /dylan/assets/<file>   — Frontend-Assets (style.css)
#
# HTML-Templates und CSS liegen in `plugins/core/dylan/`. Die Reload-Response-
# HTML bleibt bewusst inline im Plugin (Robustheit: selbst wenn alle anderen
# Templates fehlen, funktioniert der Restart-Workflow).
#
# Security: In production, consider adding authentication or
# restricting access to local network only.

class MaintenancePlugin < Dylan::Plugin
  pattern(%r{^/dylan(/|$)})
  timeout(6.0)  # /dylan/slow erlaubt bis 5s async-sleep

  ASSETS_DIR  = File.join(__dir__, 'dylan')
  ASSET_TYPES = { 'style.css' => 'text/css; charset=UTF-8' }.freeze

  def initialize
    super
    @router = nil  # injected by server
    @assets = Dylan::StaticAssets.new(dir: ASSETS_DIR, types: ASSET_TYPES)
  end

  # Inject router reference (called from server after initialization)
  def router=(router)
    @router = router
  end

  def call(host, path, request)
    base_path = path.split('?').first

    case base_path
    when %r{^/dylan/assets/([\w.-]+)$}
      @assets.serve(Regexp.last_match(1), request)
    when '/dylan/routes'
      handle_routes(request)
    when %r{^/dylan/test}
      handle_test(request)
    when '/dylan/stats'
      handle_stats(request)
    when '/dylan/reload'
      handle_reload(request)
    when %r{^/dylan/slow(?:/(\d+))?$}
      handle_slow(Regexp.last_match(1)&.to_i)
    when '/dylan', '/dylan/'
      handle_index(request)
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

  # ── Template-Loading ────────────────────────────────────────────────────────

  # Liest ein HTML-Template aus ASSETS_DIR und cached's für die Lebensdauer des
  # Prozesses. Edits an Templates werden mit /dylan/reload sichtbar.
  def load_template(name)
    @templates ||= {}
    @templates[name] ||= File.read(File.join(ASSETS_DIR, name))
  end

  # ── /dylan — Dashboard ──────────────────────────────────────────────────────

  def handle_index(request)
    Dylan::Response.html(load_template('index.html'))
  end

  # ── /dylan/routes ───────────────────────────────────────────────────────────

  def handle_routes(request)
    return error_no_router unless @router

    format = parse_query(request)['format']
    plugins = collect_plugins

    if format == 'json'
      # Explizite Hash-Klammern wichtig — Ruby 3+ würde ohne sie die Keys als
      # Keyword-Args interpretieren und json(data, status:) sich beklagen.
      Dylan::Response.json({ total: plugins.count, plugins: plugins })
    else
      rows = plugins.map { |p|
        "      <tr><td>#{p[:priority]}</td><td>#{p[:name]}</td><td><code>#{escape_html(p[:pattern])}</code></td></tr>"
      }.join("\n")

      html = load_template('routes.html')
                .gsub('{{ROWS}}',  rows)
                .gsub('{{TOTAL}}', plugins.count.to_s)
      Dylan::Response.html(html)
    end
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

      File.read(file).scan(/^class\s+(\w+Plugin)\s+</).each do |match|
        map[match[0]] = priority
      end
    end
    map
  end

  # ── /dylan/test ─────────────────────────────────────────────────────────────

  def handle_test(request)
    return error_no_router unless @router

    query = parse_query(request)
    test_path = query['path'] || '/'
    format    = query['format']

    matched = @router.plugins.find { |p| p.match?('', test_path) }

    result = if matched
      { matched: true,  path: test_path, plugin: matched.class.name, pattern: matched.pattern.inspect }
    else
      { matched: false, path: test_path, message: 'No plugin matches this path (would return 404)' }
    end

    if format == 'json'
      Dylan::Response.json(result)
    else
      html = load_template('test.html')
                .gsub('{{PATH}}',        escape_html(result[:path]))
                .gsub('{{STATUS_HTML}}', render_test_status(result))
      Dylan::Response.html(html)
    end
  end

  def render_test_status(result)
    if result[:matched]
      <<~HTML
        <div class="status-banner ok">✅ Match found!</div>
        <table>
          <tr><th>Property</th><th>Value</th></tr>
          <tr><td>Path</td><td><code>#{escape_html(result[:path])}</code></td></tr>
          <tr><td>Plugin</td><td>#{result[:plugin]}</td></tr>
          <tr><td>Pattern</td><td><code>#{escape_html(result[:pattern])}</code></td></tr>
        </table>
      HTML
    else
      <<~HTML
        <div class="status-banner error">❌ No match found</div>
        <p>Path <code>#{escape_html(result[:path])}</code> would return <strong>404 Not Found</strong>.</p>
      HTML
    end
  end

  # ── /dylan/stats ────────────────────────────────────────────────────────────

  def handle_stats(request)
    return error_no_router unless @router

    format = parse_query(request)['format']
    stats  = collect_stats

    if format == 'json'
      Dylan::Response.json(stats)
    else
      html = load_template('stats.html')
                .gsub('{{UPTIME_HUMAN}}',     stats[:uptime_human])
                .gsub('{{TOTAL_REQUESTS}}',   stats[:total_requests].to_s)
                .gsub('{{PLUGIN_COUNT}}',     stats[:plugin_count].to_s)
                .gsub('{{STARTED_AT}}',       stats[:started_at])
                .gsub('{{DISABLED_WARNING}}', render_disabled_warning(stats))
                .gsub('{{PLUGIN_ROWS}}',      render_stats_plugin_rows(stats))
      Dylan::Response.html(html)
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

  def render_disabled_warning(stats)
    return '' if stats[:disabled_plugins].empty?
    <<~HTML
      <div class="disabled-warning">
        <strong>⚠️ Circuit Breaker Active</strong><br>
        #{stats[:disabled_plugins].size} plugin(s) disabled due to repeated errors:<br>
        <strong>#{stats[:disabled_plugins].join(', ')}</strong>
      </div>
    HTML
  end

  def render_stats_plugin_rows(stats)
    return '      <tr><td colspan="2">No requests yet</td></tr>' if stats[:requests_by_plugin].empty?

    stats[:requests_by_plugin].map { |plugin, count|
      disabled    = stats[:disabled_plugins].include?(plugin)
      error_count = stats[:errors_by_plugin][plugin] || 0
      row_class   = disabled ? ' class="disabled"' : ''
      status      = disabled ? ' <span class="error-info">⚠️ DISABLED</span>' : ''
      error_info  = error_count > 0 ? " <span class=\"error-info\">(#{error_count} errors)</span>" : ''
      "      <tr#{row_class}><td>#{plugin}#{status}#{error_info}</td><td>#{count}</td></tr>"
    }.join("\n")
  end

  # ── /dylan/reload ───────────────────────────────────────────────────────────
  #
  # Reload-HTML bleibt bewusst inline (Plan-C-Robustheit): selbst wenn alle
  # anderen Templates fehlen, funktioniert die Restart-Feedback-Page.
  # Der eigentliche exit(0) läuft sowieso bevor irgendeine Response gerendert wird.

  def handle_reload(request)
    format = parse_query(request)['format']

    Thread.new do
      sleep 0.5  # Response Zeit zu senden geben
      puts "🔄 Server restart requested via /dylan/reload"
      exit(0)
    end

    if format == 'json'
      Dylan::Response.json({ status: 'restarting', message: 'Server will restart in 0.5 seconds' })
    else
      Dylan::Response.html(reload_inline_html)
    end
  end

  def reload_inline_html
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <title>Restarting...</title>
        <style>
          body { font-family: sans-serif; margin: 40px; background: #f5f5f5; text-align: center; padding-top: 100px; }
          .message { background: white; max-width: 500px; margin: 0 auto; padding: 40px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
          .spinner { border: 4px solid #f3f3f3; border-top: 4px solid #4CAF50; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 20px auto; }
          @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
          .status { margin-top: 20px; color: #666; font-size: 14px; }
        </style>
        <script>
          let attempts = 0;
          const maxAttempts = 30;
          function checkServer() {
            attempts++;
            fetch('/dylan/stats?format=json')
              .then(r => {
                if (r.ok) {
                  document.getElementById('status').textContent = 'Server is back online! Redirecting...';
                  setTimeout(() => window.location.href = '/dylan', 500);
                } else { throw new Error('Not ready'); }
              })
              .catch(() => {
                if (attempts < maxAttempts) {
                  document.getElementById('status').textContent = 'Waiting for server... (' + attempts + 's)';
                  setTimeout(checkServer, 1000);
                } else {
                  document.getElementById('status').textContent = 'Server restart taking longer than expected. Please refresh manually.';
                }
              });
          }
          setTimeout(checkServer, 2000);
        </script>
      </head>
      <body>
        <div class="message">
          <h1>🔄 Restarting Server...</h1>
          <div class="spinner"></div>
          <p id="status" class="status">Server is restarting...</p>
        </div>
      </body>
      </html>
    HTML
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

  def escape_html(str)
    str.to_s
       .gsub('&', '&amp;')
       .gsub('<', '&lt;')
       .gsub('>', '&gt;')
       .gsub('"', '&quot;')
       .gsub("'", '&#39;')
  end

  def error_no_router
    Dylan::Response.error(500, 'Router not available. Plugin not properly initialized.')
  end
end
