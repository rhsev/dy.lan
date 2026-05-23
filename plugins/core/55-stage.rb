# frozen_string_literal: true

# Dylan Plugin: Stage (Multi-Instance-fähig)
# Browser-based control panel (Stream Deck style) for Milan actions,
# live script streaming, cheat sheets, and background job monitoring.
#
# **Architektur**: StageBase ist die abstrakte Klasse mit der gesamten Logik.
# Konkrete Instanzen werden als kleine Subclasses unten definiert — jede mit
# eigenem URL-Prefix + Config-File. Bugfix in der Basis = automatisch in allen
# Instanzen.
#
# Routes pro Instance (z.B. mit Prefix /stage):
#   GET /stage              → Dashboard
#   GET /stage/assets/<f>   → CSS/JS-Assets (gecacht, shared zwischen Instanzen)
#   GET /stage/sheet/<id>   → Cheat sheet fragment (legacy)
#   GET /stage/run/<id>     → SSE stream proxy
#   GET /stage/jobs         → Job log fragment
#   GET /stage/jobs/check   → Cron hook: notify + ack pending jobs
#   GET /stage/notes/...    → Notes-Source via Milan

require 'yaml'
require 'cgi'
require 'json'
require 'uri'
require 'net/http'

# ── Abstrakte Basis ──────────────────────────────────────────────────────────

class StageBase < Dylan::Plugin
  abstract     # nicht selbst routen — nur als Basis für konkrete Instanzen
  timeout(5.0)

  SHEETS_DIR = File.join(__dir__, '..', '..', 'data', 'cheatsheet')
  ASSETS_DIR = File.join(__dir__, 'stage')
  ASSET_TYPES = {
    'style.css'                    => 'text/css; charset=UTF-8',
    'app.js'                       => 'application/javascript; charset=UTF-8',
    'MonaspaceArgon-Variable.woff2'   => 'font/woff2'
  }.freeze

  class << self
    # URL-Prefix dieser Instance (z.B. '/stage' oder '/onstage'). Subclasses setzen das.
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
    config        # ggf. Hot-Reload (mtime-Check throttled)
    clean = path.split('?').first
    # Prefix abschneiden — alle nachfolgenden Regex sind dann instance-unabhängig
    remainder = clean.sub(/\A#{Regexp.escape(self.class.url_prefix)}/, '')

    case remainder
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
    when '/jobs/check'
      handle_jobs_check
    when '/jobs'
      handle_jobs_view
    when '/agents/status'
      Dylan::Response.json(Dylan::Milan.health_check)
    when '/links'
      Dylan::Response.json({ 'sections' => link_sections })
    else
      handle_index
    end
  end

  private

  # ── Handlers ───────────────────────────────────────────────────────────────

  def handle_index
    Dylan::Response.html(render_html)
  end

  # Hinweis zu URL-Encoding: source_id und filename kommen bereits URL-encoded
  # aus der Stage-Route (Browser's encodeURIComponent → Stage-Regex captured
  # die rohe Form). Wir geben sie unverändert an Milan weiter — ein erneutes
  # URI.encode_www_form_component würde "%20" zu "%2520" doppel-encoden und
  # Dateien mit Leerzeichen unauffindbar machen.

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

  def notes_agent
    config['sheets_agent'] || 'mini'
  end

  def default_notes_source
    button = (config['sections'] || []).flat_map { |s| s['buttons'] || [] }
                                       .find    { |b| b['type'] == 'notes' }
    button&.dig('source') || 'cheaters'
  end

  def handle_stream_run(id)
    btn = all_buttons.find { |b| b['id'] == id && b['type'] == 'stream' }
    return Dylan::Response.error(404, "Stream '#{CGI.escape_html(id)}' not found") unless btn

    url_parts  = btn['url'].to_s.split('/', 3)
    agent_name = url_parts[1].to_s
    milan_path = url_parts[2] ? "/#{url_parts[2]}" : '/'

    # Fehler (auch unbekannter Agent) fliessen über das stream_error-Event;
    # die Browser-JS in app.js fängt das ab und zeigt es im Output-Frame.
    Dylan::Response.sse do |body|
      Async do
        Dylan::Milan.proxy_sse(agent_name, milan_path, body)
      ensure
        body.close
      end
    end
  end

  # Cron hook: fetch pending jobs from all Milan agents, send ntfy, ack.
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

  # Link-Grid (Flame-Ersatz): pro Sektion eine Liste aus {label, url, icon}.
  # Wird nur an /links als JSON zurückgegeben; wenn nicht konfiguriert: leer.
  def link_sections
    (config['links'] || []).map do |sec|
      items = (sec['items'] || []).map do |it|
        {
          'label' => it['label'].to_s,
          'url'   => it['url'].to_s,
          'icon'  => it['icon'].to_s
        }
      end
      { 'title' => sec['title'].to_s, 'items' => items }
    end
  end

  # ── Sidebar ─────────────────────────────────────────────────────────────────

  def render_sidebar
    html = +''
    sections.each do |sec|
      html << %(<div class="section">\n)
      html << %(<div class="section-title">#{CGI.escape_html(sec['title'].to_s)}</div>\n)
      (sec['buttons'] || []).each do |btn|
        id          = CGI.escape_html(btn['id'].to_s)
        label       = CGI.escape_html(btn['label'].to_s)
        url         = CGI.escape_html(btn['url'].to_s)
        placeholder = CGI.escape_html(btn['placeholder'].to_s)
        type = case btn['type']
               when 'cheatsheet', 'notes' then 'notes'
               when 'stream'              then 'stream'
               when 'input'               then 'input'
               when 'jobs'                then 'jobs'
               else                            'action'
               end
        source = CGI.escape_html(btn['source'].to_s)
        format = CGI.escape_html(btn['format'].to_s)
        agent = badge_agent_for(btn)
        agent_attr  = agent ? %( data-agent="#{CGI.escape_html(agent)}") : ''
        badge_html  = agent ? %(<span class="agent-badge" data-agent="#{CGI.escape_html(agent)}">#{CGI.escape_html(agent)}</span>) : ''
        html << <<~BTN
          <button class="btn btn-#{type}"
                  data-id="#{id}" data-type="#{type}"
                  data-url="#{url}" data-placeholder="#{placeholder}"
                  data-source="#{source}" data-format="#{format}"#{agent_attr}>#{badge_html}#{label}</button>
        BTN
      end
      html << %(</div>\n)
    end
    html
  end

  # Welcher Agent kriegt das Badge für diesen Button?
  # - action/stream/input: ergibt sich aus dem ersten URL-Segment
  # - notes/cheatsheet:    nutzt den konfigurierten sheets_agent (Default: mini)
  # - jobs:                aggregiert alle Agents → kein einzelner Badge
  # Liefert nil wenn kein Milan-Agent zugeordnet werden kann.
  def badge_agent_for(btn)
    case btn['type']
    when 'notes', 'cheatsheet'
      candidate = notes_agent
      Dylan::Milan.agents.key?(candidate) ? candidate : nil
    when 'jobs'
      nil
    else
      milan_agent_in_url(btn['url'])
    end
  end

  # Erstes URL-Segment, sofern es einem konfigurierten Milan-Agent entspricht.
  def milan_agent_in_url(url)
    return nil if url.to_s.empty?
    segment = url.to_s.sub(%r{^/}, '').split('/').first
    return nil if segment.nil? || segment.empty?
    Dylan::Milan.agents.key?(segment) ? segment : nil
  end

  # ── HTML ───────────────────────────────────────────────────────────────────

  def render_html
    # Template wird beim ersten Render geladen UND der instance-spezifische
    # {{PREFIX}}-Marker eingesetzt (passiert nur einmal pro Instance) — danach
    # bei jedem Render nur noch die dynamischen Felder (Title + Sidebar).
    @html_template ||= File.read(File.join(ASSETS_DIR, 'index.html'))
                            .gsub('{{PREFIX}}', self.class.url_prefix)
    @html_template.gsub('{{TITLE}}',   CGI.escape_html(stage_title))
                  .gsub('{{SIDEBAR}}', render_sidebar)
  end
end

# ── Konkrete Instanzen ──────────────────────────────────────────────────────
#
# StageBase ist abstrakt — konkrete Instanzen leben in eigenen Plugin-Dateien.
# Jede Instance = ein eigenes URL-Prefix + eine eigene YAML. Beispiele:
#
#   class MyStage < StageBase
#     pattern         %r{^/mystage(/|\?|$)}
#     url_prefix      '/mystage'
#     config_file     'mystage.yaml'
#     config_section  'stage'
#   end
#
# Ausgeliefert mit Dylan:
#   - `plugins/core/91-manage.rb` — Stage-Instance unter /manage, ruft die
#     Maintenance-Endpoints auf (Routes, Stats, ...).
#
# Eigene Instanzen kommen typischerweise in `plugins/custom/` mit Priority > 55
# damit sie nach StageBase laden.
