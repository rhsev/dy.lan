# frozen_string_literal: true

# Maintenance Plugin
# Provides server management endpoints:
#   GET  /dylan                 - Dashboard
#   GET  /dylan/routes          - List all registered plugins
#   GET  /dylan/test?path=/foo  - Test which plugin matches a path
#   GET  /dylan/stats           - Server statistics
#
# Security: In production, consider adding authentication or
# restricting access to local network only

class MaintenancePlugin < Dylan::Plugin
  pattern(%r{^/dylan(/|$)})

  def initialize
    super
    @router = nil  # Will be injected by server
  end

  # Inject router reference (called from server after initialization)
  def router=(router)
    @router = router
  end

  def call(host, path, request)
    # Strip query parameters for routing
    base_path = path.split('?').first

    # Endpoint routing
    case base_path
    when '/dylan/routes'
      handle_routes(request)
    when %r{^/dylan/test}
      handle_test(request)
    when '/dylan/stats'
      handle_stats(request)
    when '/dylan/reload'
      handle_reload(request)
    when '/dylan', '/dylan/'
      handle_index(request)
    else
      Dylan::Response.not_found
    end
  end

  private

  # GET /dylan - Dashboard
  def handle_index(request)
    accept = request.headers['accept'] || ''

    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>dy.lan Dashboard</title>
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            margin: 40px;
            background: #f5f5f5;
          }
          .container {
            max-width: 800px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
          }
          h1 { color: #333; margin-top: 0; }
          .endpoint {
            margin: 20px 0;
            padding: 15px;
            background: #f9f9f9;
            border-left: 4px solid #4CAF50;
            border-radius: 4px;
          }
          .endpoint code {
            background: #e0e0e0;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: Monaco, monospace;
          }
          a { color: #4CAF50; text-decoration: none; }
          a:hover { text-decoration: underline; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>dy.lan Dashboard</h1>
          <p>Server management and debugging endpoints.</p>

          <div class="endpoint">
            <strong><a href="/dylan/routes">/dylan/routes</a></strong>
            <p>List all registered plugins and their patterns.</p>
          </div>

          <div class="endpoint">
            <strong><a href="/dylan/stats">/dylan/stats</a></strong>
            <p>Server statistics (uptime, request counts).</p>
          </div>

          <div class="endpoint">
            <strong><a href="/dylan/test?path=/g/test">/dylan/test?path=/foo</a></strong>
            <p>Test which plugin matches a given path.</p>
          </div>

          <div class="endpoint">
            <strong><a href="/dylan/reload">/dylan/reload</a></strong>
            <p>Trigger server restart (reloads all plugins and code).</p>
          </div>

          <p style="margin-top: 40px; color: #666; font-size: 14px;">
            Add <code>?format=json</code> to any endpoint for JSON response.<br>
            YAML configs hot-reload automatically when changed.
          </p>
        </div>
      </body>
      </html>
    HTML

    Dylan::Response.html(html)
  end

  # GET /dylan/routes - List all plugins
  def handle_routes(request)
    return error_no_router unless @router

    format = parse_query(request)['format']

    # Build map of class names to priorities from plugin directory
    priority_map = {}
    if @router.plugin_dir && Dir.exist?(@router.plugin_dir)
      Dir.glob(File.join(@router.plugin_dir, '*.rb')).each do |file|
        basename = File.basename(file)
        # Extract priority from filename: "30-pattern-redirect.rb" -> "30"
        if basename =~ /^(\d+)-/
          priority = $1

          # Read file to find all class definitions
          content = File.read(file)
          content.scan(/^class\s+(\w+Plugin)\s+</).each do |match|
            class_name = match[0]
            priority_map[class_name] = priority
          end
        end
      end
    end

    plugins = @router.plugins.map.with_index do |plugin, index|
      class_name = plugin.class.name

      # Get priority from map, fallback to load order
      priority = priority_map[class_name] || format('%02d', index)

      {
        priority: priority,
        name: class_name,
        pattern: plugin.pattern.inspect
      }
    end

    # Sort by priority (numeric)
    plugins.sort_by! { |p| p[:priority].to_i }

    if format == 'json'
      Dylan::Response.json({
        total: plugins.count,
        plugins: plugins
      })
    else
      html = render_routes_html(plugins)
      Dylan::Response.html(html)
    end
  end

  # GET /dylan/test?path=/foo - Test route matching
  def handle_test(request)
    return error_no_router unless @router

    query = parse_query(request)
    test_path = query['path'] || '/'
    format = query['format']

    # Find matching plugin
    matched_plugin = nil
    @router.plugins.each do |plugin|
      if plugin.match?('', test_path)
        matched_plugin = plugin
        break
      end
    end

    result = if matched_plugin
      {
        matched: true,
        path: test_path,
        plugin: matched_plugin.class.name,
        pattern: matched_plugin.pattern.inspect
      }
    else
      {
        matched: false,
        path: test_path,
        message: 'No plugin matches this path (would return 404)'
      }
    end

    if format == 'json'
      Dylan::Response.json(result)
    else
      html = render_test_html(result)
      Dylan::Response.html(html)
    end
  end

  # GET /dylan/reload - Trigger server restart
  def handle_reload(request)
    format = parse_query(request)['format']

    # Exit with code 0 to trigger container restart (if restart policy is set)
    Thread.new do
      sleep 0.5  # Give time to send response
      puts "🔄 Server restart requested via /dylan/reload"
      exit(0)
    end

    if format == 'json'
      Dylan::Response.json({
        status: 'restarting',
        message: 'Server will restart in 0.5 seconds'
      })
    else
      html = <<~HTML
        <!DOCTYPE html>
        <html>
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
            const maxAttempts = 30; // 30 seconds

            function checkServer() {
              attempts++;
              fetch('/dylan/stats?format=json', { method: 'GET' })
                .then(response => {
                  if (response.ok) {
                    document.getElementById('status').textContent = 'Server is back online! Redirecting...';
                    setTimeout(() => window.location.href = '/dylan', 500);
                  } else {
                    throw new Error('Not ready');
                  }
                })
                .catch(() => {
                  if (attempts < maxAttempts) {
                    document.getElementById('status').textContent = `Waiting for server... (${attempts}s)`;
                    setTimeout(checkServer, 1000);
                  } else {
                    document.getElementById('status').textContent = 'Server restart taking longer than expected. Please refresh manually.';
                  }
                });
            }

            // Start checking after 2 seconds (give server time to exit)
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
      Dylan::Response.html(html)
    end
  end

  # GET /dylan/stats - Server statistics
  def handle_stats(request)
    return error_no_router unless @router

    format = parse_query(request)['format']

    uptime = @router.uptime
    stats = {
      uptime_seconds: uptime.round(2),
      uptime_human: format_duration(uptime),
      total_requests: @router.stats[:total_requests],
      requests_by_plugin: @router.stats[:requests_by_plugin],
      errors_by_plugin: @router.stats[:errors_by_plugin],
      disabled_plugins: @router.disabled_plugins.to_a,
      plugin_count: @router.route_count,
      started_at: @router.stats[:started_at].iso8601
    }

    if format == 'json'
      Dylan::Response.json(stats)
    else
      html = render_stats_html(stats)
      Dylan::Response.html(html)
    end
  end

  # Helper: Parse query string
  def parse_query(request)
    query_string = request.path.split('?', 2)[1] || ''
    query_string.split('&').each_with_object({}) do |pair, hash|
      key, value = pair.split('=', 2)
      hash[key] = value if key
    end
  end

  # Helper: Format duration
  def format_duration(seconds)
    days = (seconds / 86400).to_i
    hours = ((seconds % 86400) / 3600).to_i
    minutes = ((seconds % 3600) / 60).to_i
    secs = (seconds % 60).to_i

    parts = []
    parts << "#{days}d" if days > 0
    parts << "#{hours}h" if hours > 0
    parts << "#{minutes}m" if minutes > 0
    parts << "#{secs}s"
    parts.join(' ')
  end

  # Render routes as HTML
  def render_routes_html(plugins)
    rows = plugins.map do |p|
      "<tr><td>#{p[:priority]}</td><td>#{p[:name]}</td><td><code>#{escape_html(p[:pattern])}</code></td></tr>"
    end.join("\n")

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>Dylan Routes</title>
        <style>
          body { font-family: sans-serif; margin: 40px; background: #f5f5f5; }
          .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; }
          table { width: 100%; border-collapse: collapse; margin: 20px 0; }
          th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
          th { background: #4CAF50; color: white; }
          td:first-child { font-family: Monaco, monospace; font-size: 13px; color: #666; width: 60px; text-align: center; }
          code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 13px; font-family: Monaco, monospace; }
          a { color: #4CAF50; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>Registered Routes</h1>
          <p><a href="/dylan">← Back to Dashboard</a></p>
          <table>
            <tr><th>Priority</th><th>Plugin</th><th>Pattern</th></tr>
            #{rows}
          </table>
          <p style="color: #666; font-size: 14px;">
            Total: #{plugins.count} plugin(s) | First match wins (lower priority number = checked first)
          </p>
        </div>
      </body>
      </html>
    HTML
  end

  # Render test result as HTML
  def render_test_html(result)
    if result[:matched]
      status_html = <<~HTML
        <div style="background: #4CAF50; color: white; padding: 20px; border-radius: 4px; margin: 20px 0;">
          ✅ Match found!
        </div>
        <table style="width: 100%; border-collapse: collapse;">
          <tr><th style="text-align: left; padding: 8px; background: #f0f0f0;">Property</th><th style="text-align: left; padding: 8px; background: #f0f0f0;">Value</th></tr>
          <tr><td style="padding: 8px; border-bottom: 1px solid #ddd;">Path</td><td style="padding: 8px; border-bottom: 1px solid #ddd;"><code>#{escape_html(result[:path])}</code></td></tr>
          <tr><td style="padding: 8px; border-bottom: 1px solid #ddd;">Plugin</td><td style="padding: 8px; border-bottom: 1px solid #ddd;">#{result[:plugin]}</td></tr>
          <tr><td style="padding: 8px; border-bottom: 1px solid #ddd;">Pattern</td><td style="padding: 8px; border-bottom: 1px solid #ddd;"><code>#{escape_html(result[:pattern])}</code></td></tr>
          <tr><td style="padding: 8px;">Priority</td><td style="padding: 8px;">#{result[:priority]}</td></tr>
        </table>
      HTML
    else
      status_html = <<~HTML
        <div style="background: #f44336; color: white; padding: 20px; border-radius: 4px; margin: 20px 0;">
          ❌ No match found
        </div>
        <p>Path <code>#{escape_html(result[:path])}</code> would return <strong>404 Not Found</strong>.</p>
      HTML
    end

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>Route Test</title>
        <style>
          body { font-family: sans-serif; margin: 40px; background: #f5f5f5; }
          .container { max-width: 700px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; }
          code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
          a { color: #4CAF50; }
          input { padding: 8px; width: 300px; border: 1px solid #ddd; border-radius: 4px; }
          button { padding: 8px 16px; background: #4CAF50; color: white; border: none; border-radius: 4px; cursor: pointer; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>Route Tester</h1>
          <p><a href="/dylan">← Back to Dashboard</a></p>
          <form method="GET" action="/dylan/test">
            <input type="text" name="path" placeholder="/example/path" value="#{escape_html(result[:path])}">
            <button type="submit">Test</button>
          </form>
          #{status_html}
        </div>
      </body>
      </html>
    HTML
  end

  # Render stats as HTML
  def render_stats_html(stats)
    plugin_rows = stats[:requests_by_plugin].map do |plugin, count|
      disabled = stats[:disabled_plugins].include?(plugin)
      error_count = stats[:errors_by_plugin][plugin] || 0
      row_class = disabled ? ' style="background: #ffebee; color: #c62828;"' : ''
      status = disabled ? ' <span style="color: #c62828;">⚠️ DISABLED</span>' : ''
      error_info = error_count > 0 ? " (#{error_count} errors)" : ""
      "<tr#{row_class}><td>#{plugin}#{status}#{error_info}</td><td>#{count}</td></tr>"
    end.join("\n")

    disabled_warning = if !stats[:disabled_plugins].empty?
      <<~WARNING
        <div style="background: #ffebee; border-left: 4px solid #c62828; padding: 15px; margin: 20px 0; border-radius: 4px;">
          <strong style="color: #c62828;">⚠️ Circuit Breaker Active</strong><br>
          #{stats[:disabled_plugins].size} plugin(s) disabled due to repeated errors:<br>
          <strong>#{stats[:disabled_plugins].join(', ')}</strong>
        </div>
      WARNING
    else
      ""
    end

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <meta http-equiv="refresh" content="5">
        <title>Dylan Stats</title>
        <style>
          body { font-family: sans-serif; margin: 40px; background: #f5f5f5; }
          .container { max-width: 700px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; }
          table { width: 100%; border-collapse: collapse; margin: 20px 0; }
          th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
          th { background: #4CAF50; color: white; }
          .metric { background: #f9f9f9; padding: 15px; margin: 10px 0; border-radius: 4px; }
          .metric strong { color: #4CAF50; font-size: 24px; }
          a { color: #4CAF50; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>Server Statistics</h1>
          <p><a href="/dylan">← Back to Dashboard</a></p>

          #{disabled_warning}

          <div class="metric">
            <strong>#{stats[:uptime_human]}</strong><br>
            Uptime
          </div>

          <div class="metric">
            <strong>#{stats[:total_requests]}</strong><br>
            Total Requests
          </div>

          <div class="metric">
            <strong>#{stats[:plugin_count]}</strong><br>
            Registered Plugins
          </div>

          <h3>Requests by Plugin</h3>
          <table>
            <tr><th>Plugin</th><th>Requests</th></tr>
            #{plugin_rows.empty? ? '<tr><td colspan="2">No requests yet</td></tr>' : plugin_rows}
          </table>

          <p style="color: #666; font-size: 12px; margin-top: 30px;">
            Started: #{stats[:started_at]}<br>
            Auto-refresh: 5 seconds
          </p>
        </div>
      </body>
      </html>
    HTML
  end

  # Helper: HTML escape
  def escape_html(str)
    str.to_s
      .gsub('&', '&amp;')
      .gsub('<', '&lt;')
      .gsub('>', '&gt;')
      .gsub('"', '&quot;')
      .gsub("'", '&#39;')
  end

  # Error response when router not available
  def error_no_router
    Dylan::Response.error(500, 'Router not available. Plugin not properly initialized.')
  end
end
