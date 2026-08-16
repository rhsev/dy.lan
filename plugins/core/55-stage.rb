# frozen_string_literal: true

# Dylan Plugin: Stage (multi-instance)
# Browser-based control panel (Stream Deck style) for Milan actions,
# live script streaming, cheat sheets, and background job monitoring.
#
# **Architecture**: StageBase is the abstract class holding all logic.
# Concrete instances are defined as small subclasses below — each with its own
# URL prefix and config file. A fix in the base propagates to all instances.
#
# Routes pro Instance (z.B. mit Prefix /stage):
#   GET /stage              → Dashboard (default-Panel serverseitig aktiv)
#   GET /stage/panel/<id>   → Panel-Fragment (mit X-Requested-With: fetch) oder
#                              volle Seite mit diesem Panel aktiv (Direktaufruf)
#   GET /stage/assets/<f>   → CSS/JS-Assets (gecacht, shared zwischen Instanzen)
#   GET /stage/sheet/<id>   → Cheat sheet fragment (legacy)
#   GET /stage/run/<id>     → SSE stream proxy
#   GET /stage/jobs/check   → Cron hook: notify + ack pending jobs
#   GET /stage/notes/...    → Notes-Source via Milan
#
# Panel-Renderer (type: panel, panel: links|widget|jobs|notes) rendern
# serverseitig. action/stream/input bleiben JS-getrieben — sie sind keine
# Panels, sondern Aktionen mit Ausgabe.

require 'yaml'
require 'cgi'
require 'json'
require 'uri'
require 'net/http'
require 'time'    # Time.parse in render_jobs_fragment
require 'digest'  # ETag over the widget states

# The ANSI renderer lives in lib/ and is normally loaded by server.rb. A
# deployment that mounts only plugins/ runs the image's server.rb instead —
# then the plugin fetches it itself. If lib/ is missing there too, tiles lose
# their colour rather than taking the whole Stage down with them.
begin
  require_relative '../../lib/ansi' unless defined?(Dylan::Ansi)
rescue LoadError => e
  warn "[Stage] ANSI renderer unavailable (#{e.message}) — tiles render uncoloured"
end

# ── Abstrakte Basis ──────────────────────────────────────────────────────────

class StageBase < Dylan::Plugin
  abstract     # do not route directly — base class only
  timeout(5.0)

  SHEETS_DIR = File.join(__dir__, '..', '..', 'data', 'cheatsheet')
  ASSETS_DIR = File.join(__dir__, 'stage')
  ASSET_TYPES = {
    'style.css'                    => 'text/css; charset=UTF-8',
    'app.js'                       => 'application/javascript; charset=UTF-8',
    'MonaspaceArgon-Variable.woff2'   => 'font/woff2'
  }.freeze

  class << self
    # URL prefix for this instance (e.g. '/stage'). Set by subclasses.
    def url_prefix(prefix = nil)
      @url_prefix = prefix if prefix
      @url_prefix
    end
  end

  def initialize
    super
    @assets = Dylan::StaticAssets.new(dir: ASSETS_DIR, types: ASSET_TYPES)
  end

  def call(host, path, request)
    config        # hot-reload if needed (mtime check is throttled)
    clean = path.split('?').first
    # Strip prefix so all subsequent regexes are instance-independent
    remainder = clean.sub(/\A#{Regexp.escape(self.class.url_prefix)}/, '')

    case remainder
    when %r{^/assets/icons/([\w-]+\.svg)$}
      serve_icon(Regexp.last_match(1))
    when %r{^/assets/([\w.-]+)$}
      @assets.serve(Regexp.last_match(1), request)
    when %r{^/notes/([^/]+)/assets/(.+)$}
      handle_note_asset(Regexp.last_match(1), Regexp.last_match(2))
    when %r{^/notes/([^/]+)/(.+)$}
      handle_note_render(Regexp.last_match(1), Regexp.last_match(2))
    when %r{^/notes/([^/]+)/?$}
      handle_note_list(Regexp.last_match(1))
    when %r{^/sheet/(.+)$}
      # Legacy: kept for backwards compat, route to default notes source
      handle_note_render(default_notes_source, CGI.unescape(Regexp.last_match(1)))
    when %r{^/run/(.+)$}
      handle_stream_run(Regexp.last_match(1))
    when %r{^/panel/([\w-]+)$}
      id = Regexp.last_match(1)
      fetch_request?(request) ? handle_panel(id, request, host) : handle_index(id)
    when '/jobs/check'
      handle_jobs_check
    when '/agents/status'
      Dylan::Response.json(Dylan::Milan.health_check)
    else
      handle_index
    end
  end

  private

  # ── Handlers ───────────────────────────────────────────────────────────────

  def handle_index(active_panel_id = nil)
    html = render_html(active_panel_id)
    return Dylan::Response.html(html) unless active_panel_id

    # Same URL, two answers: /panel/<id> is a fragment for a fetch and the
    # whole page for a plain navigation. A cache that is not told about the
    # header would eventually hand one out in place of the other.
    Async::HTTP::Protocol::Response[200,
      { 'content-type' => 'text/html; charset=UTF-8',
        'vary'         => VARY_FETCH },
      Protocol::HTTP::Body::Buffered.wrap(html)]
  end

  VARY_FETCH = 'x-requested-with'

  def fetch_request?(request)
    Array(request.headers['x-requested-with']).flatten.join(',').include?('fetch')
  end

  # ── Panels (type: panel) ─────────────────────────────────────────────────
  #
  # One fragment endpoint for every panel button. The button's `panel` field
  # picks the renderer — a new panel kind is a case branch here, not a second
  # route. `/panel/<id>` always answers with the fragment; a plain browser
  # navigation (no X-Requested-With) gets the full page instead, with the
  # panel wired up as the active button — see handle_index/render_html.
  def handle_panel(id, request, host = nil)
    btn = all_buttons.find { |b| b['id'] == id && b['type'] == 'panel' }
    return Dylan::Response.error(404, "Panel '#{CGI.escape_html(id)}' not found") unless btn

    response = case btn['panel']
               when 'links'  then conditional_html(request, links_etag(btn)) { render_link_grid(btn['source'], host) }
               when 'widget' then handle_widgets(request, host)
               when 'jobs'   then handle_jobs_view
               when 'notes'  then render_notes_panel(btn['source'] || btn['id'])
               else Dylan::Response.error(404, "Panel '#{CGI.escape_html(id)}' not found")
               end

    response.headers['vary'] = VARY_FETCH unless response.headers['vary']
    response
  end

  # Links change only with the YAML — config_mtime is the whole input, unlike
  # the widget board's ETag which has to reflect live pushed state.
  def links_etag(btn)
    %("#{Digest::SHA256.hexdigest("links:#{btn['source']}:#{config_mtime.to_i}")[0, 16]}")
  end

  # Shared 304-or-render flow for ETag'd HTML fragments. The 304 repeats the
  # Vary header — a validated cache entry has to keep the same key it was
  # stored under.
  def conditional_html(request, etag)
    inm = Array(request.headers['if-none-match']).flatten.join(',')
    if !inm.empty? && (inm == '*' || inm.include?(etag))
      return Async::HTTP::Protocol::Response[304, { 'etag' => etag, 'vary' => VARY_FETCH }, []]
    end

    html = Protocol::HTTP::Body::Buffered.wrap(yield)
    Async::HTTP::Protocol::Response[200,
      { 'content-type'  => 'text/html; charset=UTF-8',
        'etag'          => etag,
        'vary'          => VARY_FETCH,
        'cache-control' => 'no-cache' },
      html]
  end

  # The stage's home view: the `default: true` panel button, if any. A stage
  # without one (e.g. /manage) keeps the plain "Button wählen" placeholder.
  def default_panel
    all_buttons.find { |b| b['type'] == 'panel' && b['default'] }
  end

  # URL-encoding note: source_id and filename arrive already URL-encoded from
  # the browser (encodeURIComponent). We forward them to Milan as-is — re-encoding
  # would turn "%20" into "%2520" and make files with spaces unreachable.

  def handle_note_list(source_id)
    Dylan::Milan.rescued(notes_agent, label: 'Notes') do
      response = Dylan::Milan.get(notes_agent, "/notes/#{source_id}")
      Dylan::Response.json(JSON.parse(response.body.empty? ? '[]' : response.body))
    end
  end

  def handle_note_render(source_id, filename)
    Dylan::Milan.rescued(notes_agent, label: 'Notes') do
      name = File.basename(filename)  # blockt Path-Traversal in der Datei-Komponente
      response = Dylan::Milan.get(notes_agent, "/notes/#{source_id}/#{name}")

      # Rewrite relative asset paths so browser fetches via Dylan (instance-aware)
      prefix = self.class.url_prefix
      html = response.body.gsub(/\b(src|href)="((images|css)\/[^"]+)"/) do
        "#{$1}=\"#{prefix}/notes/#{source_id}/assets/#{$2}\""
      end

      Dylan::Response.html(html)
    end
  end

  def handle_note_asset(source_id, asset_path)
    Dylan::Milan.rescued(notes_agent, label: 'Notes') do
      response = Dylan::Milan.get(notes_agent, "/notes/#{source_id}/assets/#{asset_path}")
      ct   = response.headers['content-type'] || 'application/octet-stream'
      body = Protocol::HTTP::Body::Buffered.wrap(response.body)
      Async::HTTP::Protocol::Response[200, { 'content-type' => ct }, body]
    end
  end

  # Notes panel: file list + empty content pane in one fragment. The list
  # click still fetches /notes/<source>/<file> as before — only the initial
  # scaffold moved server-side, so a fresh panel load is one request instead
  # of "list, then render" over two.
  def render_notes_panel(source_id)
    Dylan::Milan.rescued(notes_agent, label: 'Notes') do
      response = Dylan::Milan.get(notes_agent, "/notes/#{source_id}")
      files    = JSON.parse(response.body.empty? ? '[]' : response.body)
      Dylan::Response.html(notes_panel_html(files, source_id))
    end
  end

  def notes_panel_html(files, source_id)
    nav = if files.empty?
            '<div class="notes-empty">Keine Dateien</div>'
          else
            files.map do |f|
              escaped = CGI.escape_html(f)
              %(<div class="note-item" data-source="#{CGI.escape_html(source_id)}" data-file="#{escaped}">#{escaped}</div>)
            end.join
          end

    <<~HTML
      <div class="notes-layout">
        <div class="notes-nav" id="notes-nav">#{nav}</div>
        <div class="notes-content" id="notes-content">
          <div class="notes-placeholder">Datei wählen</div>
        </div>
      </div>
    HTML
  end

  ICONS_DIR = File.join(ASSETS_DIR, 'icons')

  # Renders an icon: emoji directly, mdi:<name> as inline SVG. Inline SVG
  # allows CSS color control via currentColor — no filter trick needed. SVG
  # content is cached (one file read per icon).
  # icon_color: named Nord variable (teal, blue, red, grn, yel, pur) or any hex value.
  def render_icon(icon, icon_color, svg_class:, emoji_class:)
    return '' if icon.to_s.empty?
    style = icon_color_style(icon_color)
    if icon.start_with?('mdi:')
      name = icon.sub('mdi:', '').gsub(/[^\w-]/, '')
      svg  = inline_icon(name)
      svg ? %(<span class="#{svg_class}"#{style}>#{svg}</span>) : ''
    else
      %(<span class="#{emoji_class}">#{CGI.escape_html(icon)}</span>)
    end
  end

  def render_btn_icon(icon, _prefix, icon_color = nil)
    render_icon(icon, icon_color, svg_class: 'btn-icon', emoji_class: 'btn-emoji')
  end

  def render_link_icon(icon, icon_color)
    render_icon(icon, icon_color, svg_class: 'link-icon-mdi', emoji_class: 'link-icon')
  end

  ICON_COLOR_VARS = %w[teal blue red grn yel pur n9 n10].freeze

  def icon_color_style(color)
    return '' if color.nil? || color.strip.empty?
    value = ICON_COLOR_VARS.include?(color) ? "var(--#{color})" : color
    %( style="color: #{CGI.escape_html(value)}")
  end

  def inline_icon(name)
    @icon_cache ||= {}
    @icon_cache[name] ||= begin
      path = File.join(ICONS_DIR, "#{name}.svg")
      return nil unless File.exist?(path)
      # rewrite fill to currentColor so CSS controls the colour
      File.read(path).sub(/\bfill="[^"]*"/, '').sub('<path ', '<path fill="currentColor" ')
    end
  end

  def serve_icon(filename)
    path = File.join(ICONS_DIR, filename)
    return Dylan::Response.error(404, "Icon not found") unless File.exist?(path)
    body = Protocol::HTTP::Body::Buffered.wrap(File.binread(path))
    Async::HTTP::Protocol::Response[200,
      { 'content-type' => 'image/svg+xml',
        'cache-control' => 'public, max-age=86400' },
      body]
  end

  def notes_agent
    config['sheets_agent'] || 'mini'
  end

  def default_notes_source
    button = all_buttons.find { |b| b['type'] == 'panel' && b['panel'] == 'notes' }
    button&.dig('source') || 'cheaters'
  end

  def handle_stream_run(id)
    btn = all_buttons.find { |b| b['id'] == id && b['type'] == 'stream' }
    return Dylan::Response.error(404, "Stream '#{CGI.escape_html(id)}' not found") unless btn

    url_parts  = btn['url'].to_s.split('/', 3)
    agent_name = url_parts[1].to_s
    milan_path = url_parts[2] ? "/#{url_parts[2]}" : '/'

    # Errors (including unknown agent) flow through the stream_error event;
    # app.js catches them and displays the message in the output frame.
    Dylan::Response.sse do |body|
      Async do
        Dylan::Milan.proxy_sse(agent_name, milan_path, body)
      ensure
        body.close
      end
    end
  end

  # Cron hook: fetch pending jobs from all Milan agents, send ntfy notification, ack.
  def handle_jobs_check
    results = []

    Dylan::Milan.agents.each_key do |agent_name|
      begin
        body = Dylan::Milan.get(agent_name, '/jobs/pending').body
        JSON.parse(body.empty? ? '[]' : body).each do |job|
          script  = job['script']
          exit_ok = job['exit_ok']
          job_id  = job['id']
          icon    = exit_ok ? '✓' : '✗'
          msg     = "#{icon} #{script} #{exit_ok ? 'completed' : 'failed'} (#{agent_name})"

          notify_ntfy(msg)
          Dylan::Milan.get(agent_name, "/jobs/ack/#{URI.encode_www_form_component(job_id)}") rescue nil
          results << msg
        end
      rescue => e
        results << "#{agent_name}: error — #{e.message}"
      end
    end

    Dylan::Response.text(results.empty? ? 'no pending jobs' : results.join("\n"))
  end

  # Returns HTML fragment with job cards for all Milan agents.
  def handle_jobs_view
    all_jobs = Dylan::Milan.agents.each_key.flat_map do |agent_name|
      body = Dylan::Milan.get(agent_name, '/jobs/all').body
      JSON.parse(body.empty? ? '[]' : body).each { |j| j['agent'] = agent_name }
    rescue
      []
    end

    all_jobs.sort_by! { |j| j['ts'] || '' }
    all_jobs.reverse!

    Dylan::Response.html(render_jobs_fragment(all_jobs))
  end

  # ── Widgets (type: widget) ─────────────────────────────────────────────────
  #
  # Passive state tiles. Scripts push their state to Milan's widget inbox,
  # the board shows it. One refresh is **one** request to Milan, no matter how
  # many tiles — the mapping from target to tile happens here.
  #
  # The response carries an ETag over the tile states, so the usual answer to a
  # poll is 304: no render, no transfer. Staleness is part of the ETag input,
  # otherwise a tile that just ran out of its ttl would keep the fresh look
  # until the next push.

  def widget_agent
    config['agent'] || notes_agent
  end

  def handle_widgets(request, host = nil)
    Dylan::Milan.rescued(widget_agent, label: 'Widgets') do
      body    = Dylan::Milan.get(widget_agent, '/widgets').body
      widgets = JSON.parse(body.empty? ? '[]' : body)
      widgets = [] unless widgets.is_a?(Array)

      conditional_html(request, widgets_etag(widgets)) { render_widget_board(widgets, host) }
    end
  end

  # Config mtime is part of the digest: renaming a tile in the YAML must show
  # up even when no script has pushed since.
  def widgets_etag(widgets)
    material = widgets.map do |widget|
      [widget['target'], widget['updated_at'], stale?(widget) ? 1 : 0].join(':')
    end
    %("#{Digest::SHA256.hexdigest([config_mtime.to_i, *material].join('|'))[0, 16]}")
  end

  def stale?(widget)
    ttl = widget['ttl'].to_i
    return false if ttl <= 0
    Time.now.to_i > widget['updated_at'].to_i + ttl
  end

  # Sections keep their order from the YAML; `discover: true` appends every
  # target Milan knows that no configured tile claims — that saves maintaining
  # the YAML for throwaway targets.
  def render_widget_board(widgets, host = nil)
    by_target = widgets.each_with_object({}) { |w, acc| acc[w['target'].to_s] = w }
    claimed   = all_buttons.select { |b| b['type'] == 'widget' }
                           .map    { |b| (b['target'] || b['id']).to_s }

    blocks = sections.filter_map do |sec|
      tiles = (sec['buttons'] || []).select { |b| b['type'] == 'widget' }.map do |btn|
        target = (btn['target'] || btn['id']).to_s
        render_widget_tile(btn, by_target[target], target, host)
      end

      if sec['discover']
        (widgets.map { |w| w['target'].to_s } - claimed).each do |target|
          tiles << render_widget_tile({}, by_target[target], target, host)
        end
      end

      next if tiles.empty?
      %(<h3 class="tile-section">#{CGI.escape_html(sec['title'].to_s)}</h3>) +
        %(<div class="tile-grid">#{tiles.join}</div>)
    end

    return '<div class="tile-empty">Keine Kacheln.</div>' if blocks.empty?
    %(<div class="tile-board">#{blocks.join}</div>)
  end

  # A configured tile without data still gets drawn — an empty slot says
  # "nothing has run yet", a missing slot says nothing at all.
  def render_widget_tile(btn, widget, target, host = nil)
    widget ||= {}
    label = btn['label'] || widget['title'] || target
    icon  = (btn['icon'] || widget['icon']).to_s
    color = (widget['color'] || btn['color']).to_s
    text  = widget['text'].to_s
    empty = widget.empty?

    classes = ['tile']
    classes << 'stale' if stale?(widget)
    classes << 'empty' if empty

    <<~TILE
      <div class="#{classes.join(' ')}" data-target="#{CGI.escape_html(target)}">
        <div class="tile-head">
          #{widget_dot(color)}#{widget_icon(icon)}
          <span class="tile-label">#{CGI.escape_html(label.to_s)}</span>
          <span class="tile-time">#{widget_time(widget)}</span>#{widget_doc(btn['doc'], label, host)}
        </div>
        <div class="tile-text">#{empty ? '–' : render_tile_text(text)}</div>
        #{widget_bar(widget['progress'])}
      </div>
    TILE
  end

  # Ohne den Renderer bleibt der Text lesbar — nur eben ohne Farben, und mit
  # sichtbaren Escape-Sequenzen statt stillschweigend eingeschleustem Markup.
  def render_tile_text(text)
    defined?(Dylan::Ansi) ? Dylan::Ansi.to_html(text) : CGI.escape_html(text)
  end

  # Icon names are Dylan's own short vocabulary (download, check, warn …),
  # resolved against the shared icon set. An unknown name renders nothing —
  # never an error, and never a broken image.
  def widget_icon(name)
    return '' unless name.match?(/\A[\w-]{1,32}\z/)
    svg = inline_icon(name)
    svg ? %(<span class="btn-icon">#{svg}</span>) : ''
  end

  def widget_dot(color)
    return '' if color.empty?
    return '' unless color.match?(/\A(#[0-9a-fA-F]{3,8}|[a-z]{3,20})\z/)
    %(<span class="tile-dot" style="background: #{color}"></span>)
  end

  # Clock time of the last state, not "4 minutes ago": for a slow state that is
  # the normal and correct answer, and an absolute time does not churn the ETag
  # once a minute.
  def widget_time(widget)
    stamp = widget['updated_at'].to_i
    return '' if stamp.zero?
    Time.at(stamp).strftime('%H:%M')
  end

  # The doc link comes from the YAML and never from the push. A tile shows a
  # state; where that state is explained is a property of the display. Read it
  # from the widget instead and any producer could hang links in the interface.
  #
  # http(s) and site-relative only — the vocabulary of a documentation link,
  # and nothing that executes.
  def widget_doc(url, label, host = nil)
    url = url.to_s
    return '' if url.empty?
    return '' unless url.start_with?('/') || url.match?(%r{\Ahttps?://}i)

    attr  = external_link?(url, host) ? ' target="_blank" rel="noopener"' : ''
    title = "Doku: #{label}"
    %(<a class="tile-doc" href="#{CGI.escape_html(url)}"#{attr} ) +
      %(title="#{CGI.escape_html(title)}" aria-label="#{CGI.escape_html(title)}">&#9432;</a>)
  end

  def widget_bar(progress)
    return '' if progress.nil?
    pct = progress.to_i.clamp(0, 100)
    %(<div class="tile-bar"><div class="tile-bar-fill" style="width: #{pct}%"></div></div>) +
      %(<div class="tile-pct">#{pct}%</div>)
  end

  # Poll interval for a `panel: widget` button — configured per button via
  # `refresh:`, not per stage: the interval is a property of that panel now.
  WIDGET_REFRESH_DEFAULT = 3

  def panel_refresh(btn)
    seconds = btn['refresh'].to_i
    seconds.positive? ? seconds : WIDGET_REFRESH_DEFAULT
  end

  # ── Notifications ──────────────────────────────────────────────────────────

  def notify_ntfy(msg)
    cfg = config['ntfy']
    return unless cfg&.dig('url') && cfg&.dig('topic')
    return if cfg['url'].to_s.strip.empty?

    uri = URI("#{cfg['url'].chomp('/')}/#{cfg['topic']}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 4
    http.read_timeout = 4
    req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
    req['Title']        = 'Stage Job'
    req['Content-Type'] = 'text/plain; charset=utf-8'
    req.body = msg
    http.request(req)
  rescue => e
    warn "[Stage] ntfy: #{e.message}"
  end

  # ── Jobs fragment ──────────────────────────────────────────────────────────

  def render_jobs_fragment(jobs)
    return "<div class='jobs-empty'>Keine Jobs gefunden.</div>" if jobs.empty?

    cards = jobs.map do |job|
      ok     = job['exit_ok']
      ack    = job['acknowledged']
      state  = ok ? 'ok' : 'error'
      icon   = ok ? '✓' : '✗'
      ts_raw = job['ts']
      ts     = ts_raw ? Time.parse(ts_raw).strftime('%d.%m. %H:%M:%S') : '?'
      agent  = CGI.escape_html(job['agent'].to_s)
      script = CGI.escape_html(job['script'].to_s)

      <<~CARD
        <div class="job-card #{state}#{ack ? ' ack' : ''}">
          <div class="job-header">
            <span class="job-icon">#{icon}</span>
            <span class="job-script">#{script}</span>
            <span class="job-agent">#{agent}</span>
          </div>
          <div class="job-meta">#{CGI.escape_html(ts)}#{ack ? ' · erledigt' : ' · ausstehend'}</div>
        </div>
      CARD
    end.join("\n")

    "<div class='jobs-list'>#{cards}</div>"
  end

  # ── Config ─────────────────────────────────────────────────────────────────

  def stage_title
    config['title'] || 'Stage'
  end

  def sections
    config['sections'] || []
  end

  def all_buttons
    sections.flat_map { |s| s['buttons'] || [] }
  end

  # Link grid (Flame replacement): one list of {label, url, icon} per section.
  # `links:` is a flat array (the default/only source) unless a button names a
  # second one via `source:` — then `links:` becomes a hash keyed by source
  # name. HTML for the panel comes from render_link_grid below.
  def link_sections(source = nil)
    raw  = config['links']
    list = raw.is_a?(Hash) ? (raw[source.to_s] || raw['default'] || []) : (raw || [])
    list.map do |sec|
      items = (sec['items'] || []).map do |it|
        item = {
          'label' => it['label'].to_s,
          'url'   => it['url'].to_s,
          'icon'  => it['icon'].to_s
        }
        item['icon_color'] = it['icon_color'].to_s if it['icon_color']
        item
      end
      { 'title' => sec['title'].to_s, 'items' => items }
    end
  end

  def render_link_grid(source = nil, host = nil)
    blocks = link_sections(source).filter_map do |sec|
      next if sec['items'].empty?
      items = sec['items'].map { |it| render_link_card(it, host) }.join
      %(<h3 class="link-grid-title">#{CGI.escape_html(sec['title'])}</h3>) +
        %(<div class="link-grid">#{items}</div>)
    end
    return '<div class="link-grid-empty">Keine Links konfiguriert.</div>' if blocks.empty?
    %(<div class="link-grid-wrap">#{blocks.join}</div>)
  end

  def render_link_card(item, host = nil)
    url  = item['url']
    attr = external_link?(url, host) ? ' target="_blank" rel="noopener"' : ''
    icon = render_link_icon(item['icon'], item['icon_color'])
    %(<a class="link-card" href="#{CGI.escape_html(url)}"#{attr}>#{icon}<span class="link-label">#{CGI.escape_html(item['label'])}</span></a>)
  end

  # A new tab is for links that leave this instance. Relative URLs never do;
  # an absolute one only when its host differs from the one the page was
  # requested under — otherwise /monitor and http://dy.lan/monitor would
  # behave differently for no visible reason.
  def external_link?(url, host = nil)
    return false unless url.match?(%r{\A[a-z][a-z0-9+.\-]*:}i)
    return true if host.to_s.empty?

    target = begin
      URI.parse(url).host
    rescue URI::InvalidURIError
      nil
    end
    return true if target.nil?  # shortcuts://, mailto: — not this instance either

    !target.casecmp?(host.to_s.split(':').first.to_s)
  end

  # ── Sidebar ────────────────────────────────────────────────────────────────

  def render_sidebar(active: nil)
    html = +''
    sections.each do |sec|
      # Widget tiles are read, not pressed — they live in the board panel, and
      # a section holding nothing else does not need a sidebar heading.
      buttons = (sec['buttons'] || []).reject { |b| b['type'] == 'widget' }
      next if buttons.empty?

      html << %(<div class="section">\n)
      html << %(<div class="section-title">#{CGI.escape_html(sec['title'].to_s)}</div>\n)
      buttons.each do |btn|
        id          = CGI.escape_html(btn['id'].to_s)
        label       = CGI.escape_html(btn['label'].to_s)
        url         = CGI.escape_html(btn['url'].to_s)
        placeholder = CGI.escape_html(btn['placeholder'].to_s)
        type = case btn['type']
               when 'stream' then 'stream'
               when 'input'  then 'input'
               when 'panel'  then 'panel'
               else               'action'
               end
        source       = CGI.escape_html(btn['source'].to_s)
        format       = CGI.escape_html(btn['format'].to_s)
        icon_html    = render_btn_icon(btn['icon'].to_s, self.class.url_prefix, btn['icon_color'])
        agent        = badge_agent_for(btn)
        agent_attr   = agent ? %( data-agent="#{CGI.escape_html(agent)}") : ''
        badge_html   = agent ? %(<span class="agent-badge" data-agent="#{CGI.escape_html(agent)}">#{CGI.escape_html(agent)}</span>) : ''
        panel_attr   = type == 'panel' ? %( data-panel="#{CGI.escape_html(btn['panel'].to_s)}") : ''
        refresh_attr = (type == 'panel' && btn['panel'] == 'widget') ? %( data-refresh="#{panel_refresh(btn)}") : ''
        active_class = (active && btn['id'].to_s == active.to_s) ? ' active' : ''
        html << <<~BTN
          <button class="btn btn-#{type}#{active_class}"
                  data-id="#{id}" data-type="#{type}"
                  data-url="#{url}" data-placeholder="#{placeholder}"
                  data-source="#{source}" data-format="#{format}"#{panel_attr}#{refresh_attr}#{agent_attr}>#{badge_html}#{icon_html}#{label}</button>
        BTN
      end
      html << %(</div>\n)
    end
    html
  end

  # Which agent gets the badge for this button?
  # - action/stream/input:    derived from the first URL segment
  # - panel:notes:            uses the configured sheets_agent (default: mini)
  # - panel:jobs:             aggregates all agents → no single badge
  # Returns nil if no Milan agent can be associated.
  def badge_agent_for(btn)
    kind = btn['type'] == 'panel' ? btn['panel'] : btn['type']
    case kind
    when 'notes'
      candidate = notes_agent
      Dylan::Milan.agents.key?(candidate) ? candidate : nil
    when 'jobs'
      nil
    else
      milan_agent_in_url(btn['url'])
    end
  end

  # First URL segment if it matches a configured Milan agent name.
  def milan_agent_in_url(url)
    return nil if url.to_s.empty?
    segment = url.to_s.sub(%r{^/}, '').split('/').first
    return nil if segment.nil? || segment.empty?
    Dylan::Milan.agents.key?(segment) ? segment : nil
  end

  # ── HTML ───────────────────────────────────────────────────────────────────

  def render_html(active_panel_id = nil)
    # Template is loaded once and the instance-specific {{PREFIX}} placeholder
    # is substituted on first render — subsequent renders only replace the
    # dynamic fields (title, sidebar, active panel).
    @html_template ||= File.read(File.join(ASSETS_DIR, 'index.html'))
                            .gsub('{{PREFIX}}', self.class.url_prefix)
    panel_id = active_panel_id || default_panel&.dig('id')
    @html_template.gsub('{{TITLE}}',        CGI.escape_html(stage_title))
                  .gsub('{{ACTIVE_PANEL}}', CGI.escape_html(panel_id.to_s))
                  .gsub('{{SIDEBAR}}',      render_sidebar(active: panel_id))
  end
end

# ── Concrete instances ──────────────────────────────────────────────────────
#
# StageBase is abstract — concrete instances live in separate plugin files.
# Each instance gets its own URL prefix and YAML config file. Examples:
#
#   class MyStage < StageBase
#     pattern         %r{^/mystage(/|\?|$)}
#     url_prefix      '/mystage'
#     config_file     'mystage.yaml'
#     config_section  'stage'
#   end
#
# Shipped with Dylan:
#   - `plugins/core/91-manage.rb` — Stage instance at /manage, wired to the
#     maintenance endpoints (routes, stats, ...).
#
# Custom instances typically go in `plugins/custom/` with priority > 55
# so they load after StageBase.
