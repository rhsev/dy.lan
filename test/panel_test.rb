# frozen_string_literal: true

# ruby test/panel_test.rb
#
# Deckt den Panel-Teil von StageBase ab: Panel-Auflösung (id → Renderer,
# unbekannte id → 404), render_link_grid, und den Kachel-Teil (Zuordnung
# Target → Kachel, discover, ttl-Ausgrauen, ETag — der Normalfall eines
# Board-Polls ist ein 304). Kein HTTP-Server im Spiel — Milan wird gestubbt.

require 'minitest/autorun'
require 'json'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/static_assets'
require_relative '../lib/milan'
require_relative '../lib/ansi'
require_relative '../plugins/core/55-stage'

# Milan-Stub: liefert, was der Test vorher hingelegt hat.
module MilanStub
  attr_accessor :stub_body

  def get(_agent, _path)
    Dylan::Milan::Response.new(200, {}, stub_body.to_s)
  end
end
Dylan::Milan.singleton_class.prepend(MilanStub)

# Stage-Instanz mit Config aus dem Test statt aus einer YAML-Datei.
class TestStage < StageBase
  pattern    %r{^/stage}
  url_prefix '/stage'

  def initialize(config)
    super()
    @test_config = config
  end

  def config = @test_config
  def config_mtime = 0
end

FakeRequest = Struct.new(:headers)

class PanelTest < Minitest::Test
  def setup
    @now = Time.now.to_i
  end

  def stage(sections, extra = {})
    TestStage.new({ 'title' => 'Stage', 'agent' => 'mini', 'sections' => sections }.merge(extra))
  end

  def widget(target, **fields)
    { 'target' => target, 'updated_at' => @now }.merge(fields.transform_keys(&:to_s))
  end

  # Ruft /widgets auf und gibt [status, headers, body] zurück.
  def get_widgets(stg, widgets, headers = {})
    Dylan::Milan.stub_body = JSON.generate(widgets)
    response = stg.send(:handle_widgets, FakeRequest.new(headers))
    body = +''
    while (chunk = response.body&.read)
      body << chunk
    end
    [response.status, response.headers, body]
  end

  # headers[] liefert je nach Weg String oder Array — normalisieren.
  def vary(response) = Array(response.headers['vary']).flatten.join(',')

  def tile_section
    [{ 'title' => 'Läuft',
       'buttons' => [{ 'id' => 'copy', 'type' => 'widget', 'target' => 'copy', 'label' => 'Backup' }] }]
  end

  # ── Kacheln ──────────────────────────────────────────────────────────────

  def test_tile_shows_pushed_state
    status, _, html = get_widgets(stage(tile_section),
                                  [widget('copy', text: 'archive.zip', progress: 42, ttl: 120)])

    assert_equal 200, status
    assert_includes html, 'data-target="copy"'
    assert_includes html, 'Backup'          # Label aus der YAML
    assert_includes html, 'archive.zip'
    assert_includes html, 'width: 42%'
    refute_includes html, 'stale'
  end

  # Eine konfigurierte Kachel ohne Daten bleibt sichtbar: ein leerer Platz sagt
  # „hier lief noch nichts", ein fehlender Platz sagt gar nichts.
  def test_configured_tile_without_data_still_renders
    _, _, html = get_widgets(stage(tile_section), [])
    assert_includes html, 'data-target="copy"'
    assert_includes html, 'class="tile empty"'
  end

  # ttl abgelaufen = etwas, das laufen sollte, tut es nicht mehr. Muss als tot
  # erkennbar sein, sonst liest man alte Zahlen für aktuelle.
  def test_expired_ttl_greys_out
    stale = widget('copy', text: 'archive.zip', ttl: 60, updated_at: @now - 600)
    _, _, html = get_widgets(stage(tile_section), [stale])
    assert_includes html, 'tile stale'

    fresh = widget('copy', text: 'archive.zip', ttl: 60)
    _, _, html = get_widgets(stage(tile_section), [fresh])
    refute_includes html, 'tile stale'
  end

  # Ohne ttl ist „vor 4 Minuten" die normale und richtige Antwort, kein Fehler.
  def test_without_ttl_never_goes_stale
    old = widget('na', text: '3 Aufgaben', updated_at: @now - 86_400, color: '#34c759')
    sections = [{ 'title' => 'Zustand',
                  'buttons' => [{ 'id' => 'na', 'type' => 'widget', 'target' => 'na' }] }]
    _, _, html = get_widgets(stage(sections), [old])

    refute_includes html, 'stale'
    assert_includes html, 'background: #34c759'
    assert_includes html, Time.at(@now - 86_400).strftime('%H:%M')
  end

  def test_discover_shows_unclaimed_targets
    sections = tile_section + [{ 'title' => 'Sonstiges', 'discover' => true }]
    _, _, html = get_widgets(stage(sections),
                             [widget('copy', text: 'a'), widget('wegwerf', text: 'b')])

    assert_includes html, 'data-target="wegwerf"'
    assert_equal 1, html.scan('data-target="copy"').size, 'discover darf keine Kachel doppeln'
  end

  def test_ansi_and_escaping_in_tile_text
    _, _, html = get_widgets(stage(tile_section), [widget('copy', text: "\e[32mok\e[0m <b>")])
    assert_includes html, '<span class="ansi-fg-green">ok</span>'
    assert_includes html, '&lt;b&gt;'
    refute_includes html, '<b>'
  end

  # Ein Board-Refresh ist ein Request an Milan, egal wie viele Kacheln.
  def test_one_milan_request_per_refresh
    calls = 0
    Dylan::Milan.singleton_class.prepend(Module.new do
      define_method(:get) do |agent, path|
        calls += 1
        super(agent, path)
      end
    end)

    sections = [{ 'title' => 'Alle',
                  'buttons' => %w[a b c].map { |t| { 'id' => t, 'type' => 'widget', 'target' => t } } }]
    get_widgets(stage(sections), %w[a b c].map { |t| widget(t, text: t) })
    assert_equal 1, calls
  end

  # ── ETag ───────────────────────────────────────────────────────────────────

  def test_unchanged_state_answers_304
    widgets = [widget('copy', text: 'archive.zip', progress: 10)]
    _, headers, = get_widgets(stage(tile_section), widgets)
    etag = headers['etag']
    refute_nil etag

    status, _, body = get_widgets(stage(tile_section), widgets, 'if-none-match' => etag)
    assert_equal 304, status
    assert_empty body
  end

  def test_new_push_changes_the_etag
    _, first, = get_widgets(stage(tile_section), [widget('copy', text: 'a')])
    _, second, = get_widgets(stage(tile_section),
                             [widget('copy', text: 'b', updated_at: @now + 1)])
    refute_equal first['etag'], second['etag']
  end

  # Sonst behielte eine gerade abgelaufene Kachel das frische Aussehen bis zum
  # nächsten Push — der Zeitpunkt, an dem man am ehesten hinschaut.
  # Gleicher Stand, gleicher Push-Zeitpunkt — nur einmal noch innerhalb der ttl
  # und einmal darüber hinaus. Der ETag muss das unterscheiden.
  def test_expiring_changes_the_etag_without_a_push
    pushed_at = @now - 30
    fresh   = widget('copy', text: 'läuft', ttl: 60,  updated_at: pushed_at)
    expired = widget('copy', text: 'läuft', ttl: 10,  updated_at: pushed_at)

    _, before, = get_widgets(stage(tile_section), [fresh])
    _, after,  = get_widgets(stage(tile_section), [expired])
    refute_equal before['etag'], after['etag']
  end

  # ── Sidebar ────────────────────────────────────────────────────────────────

  # Kacheln will man ansehen, nicht drücken: in der Sidebar haben sie nichts
  # verloren — und eine Section, die nur aus Kacheln besteht, auch keinen Titel.
  def test_widget_buttons_stay_out_of_the_sidebar
    sections = tile_section + [{ 'title' => 'Actions',
                                 'buttons' => [{ 'id' => 'hello', 'type' => 'action', 'label' => 'Hallo' }] }]
    sidebar = stage(sections).send(:render_sidebar)

    refute_includes sidebar, 'Backup'
    refute_includes sidebar, 'Läuft'
    assert_includes sidebar, 'Hallo'
  end

  # Ein panel-Button trägt seinen Renderer und (bei panel: widget) sein
  # Poll-Intervall als data-Attribute — das JS braucht keinen globalen Zustand.
  def test_panel_button_carries_panel_and_refresh_attrs
    sections = [{ 'title' => 'Ansichten',
                  'buttons' => [
                    { 'id' => 'links', 'type' => 'panel', 'panel' => 'links', 'label' => 'Links', 'default' => true },
                    { 'id' => 'board', 'type' => 'panel', 'panel' => 'widget', 'label' => 'Board', 'refresh' => 7 }
                  ] }]
    sidebar = stage(sections).send(:render_sidebar, active: 'links')

    assert_includes sidebar, 'data-panel="links"'
    assert_includes sidebar, 'data-panel="widget"'
    assert_includes sidebar, 'data-refresh="7"'
    assert_includes sidebar, 'btn btn-panel active'
  end

  # ── Panel-Auflösung (id → Renderer) ────────────────────────────────────────

  def panel_sections
    [{ 'title' => 'Ansichten',
       'buttons' => [
         { 'id' => 'links', 'type' => 'panel', 'panel' => 'links', 'default' => true },
         { 'id' => 'board', 'type' => 'panel', 'panel' => 'widget' },
         { 'id' => 'jobs',  'type' => 'panel', 'panel' => 'jobs' },
         { 'id' => 'notes', 'type' => 'panel', 'panel' => 'notes', 'source' => 'cheaters' },
         { 'id' => 'action_only', 'type' => 'action', 'url' => '/mini/hello' }
       ] }]
  end

  def test_unknown_panel_id_is_404
    response = stage(panel_sections).send(:handle_panel, 'nope', FakeRequest.new({}))
    assert_equal 404, response.status
  end

  # Eine bestehende id mit einem anderen Typ ist kein Panel — auch 404, nicht
  # etwa ein Fallback auf irgendeine Aktion.
  def test_non_panel_button_id_is_404
    response = stage(panel_sections).send(:handle_panel, 'action_only', FakeRequest.new({}))
    assert_equal 404, response.status
  end

  def test_panel_widget_dispatches_to_widget_board
    Dylan::Milan.stub_body = JSON.generate([])
    response = stage(panel_sections).send(:handle_panel, 'board', FakeRequest.new({}))
    assert_equal 200, response.status
  end

  def test_panel_jobs_dispatches_to_jobs_fragment
    Dylan::Milan.stub_body = JSON.generate([])  # /jobs/all pro Agent — leere Liste reicht für den Dispatch-Test
    response = stage(panel_sections).send(:handle_panel, 'jobs', FakeRequest.new({}))
    assert_equal 200, response.status
  end

  def test_panel_notes_dispatches_to_notes_panel
    Dylan::Milan.stub_body = JSON.generate(['a.md', 'b.md'])
    response = stage(panel_sections).send(:handle_panel, 'notes', FakeRequest.new({}))
    body = response.body.read
    assert_includes body, 'data-file="a.md"'
    assert_includes body, 'data-source="cheaters"'
  end

  # Dieselbe URL liefert je nach X-Requested-With ein Fragment oder die ganze
  # Seite — ohne Vary reicht ein Cache irgendwann das eine fürs andere durch.
  def test_panel_answers_vary_on_every_branch
    Dylan::Milan.stub_body = JSON.generate([])
    stg = stage(panel_sections)

    %w[links board jobs notes].each do |id|
      response = stg.send(:handle_panel, id, FakeRequest.new({}))
      assert_equal 'x-requested-with', vary(response), "Panel '#{id}' ohne Vary"
    end

    etag = Array(stg.send(:handle_panel, 'links', FakeRequest.new({})).headers['etag']).flatten.first
    not_modified = stg.send(:handle_panel, 'links', FakeRequest.new({ 'if-none-match' => etag }))
    assert_equal 304, not_modified.status
    assert_equal 'x-requested-with', vary(not_modified), '304 muss denselben Cache-Key tragen'
  end

  # ── Links-Grid ─────────────────────────────────────────────────────────────

  def test_render_link_grid_renders_sections_and_cards
    stg = stage([], 'links' => [
                   { 'title' => 'Dylan',
                     'items' => [{ 'label' => 'Reload', 'url' => '/reload', 'icon' => 'mdi:reload' }] }
                 ])
    html = stg.send(:render_link_grid)

    assert_includes html, 'link-grid-title">Dylan'
    assert_includes html, 'href="/reload"'
    assert_includes html, 'link-label">Reload'
    refute_includes html, 'target="_blank"'  # relative URL bleibt im selben Tab
  end

  def test_render_link_grid_opens_external_urls_in_new_tab
    stg = stage([], 'links' => [
                   { 'title' => 'Apps', 'items' => [{ 'label' => 'Forgejo', 'url' => 'https://apps.example.com/' }] }
                 ])
    assert_includes stg.send(:render_link_grid), 'target="_blank"'
  end

  # Ein absoluter Link auf die eigene Instanz bleibt im Tab: /monitor und
  # http://dy.lan/monitor sollen sich nicht unterschiedlich verhalten.
  def test_render_link_grid_keeps_same_host_in_tab
    stg = stage([], 'links' => [
                   { 'title' => 'Dylan',
                     'items' => [{ 'label' => 'Monitor', 'url' => 'http://dy.lan/monitor' },
                                 { 'label' => 'Fremd',   'url' => 'http://192.168.0.10:3000' },
                                 { 'label' => 'Shortcut', 'url' => 'shortcuts://run-shortcut?name=x' }] }
                 ])
    html = stg.send(:render_link_grid, nil, 'dy.lan')

    assert_equal 2, html.scan('target="_blank"').size
    refute_match %r{href="http://dy\.lan/monitor"[^>]*target}, html
    assert_match %r{href="http://192\.168\.0\.10:3000"[^>]*target="_blank"}, html
  end

  def test_render_link_grid_named_source
    stg = stage([], 'links' => {
                   'default' => [{ 'title' => 'Home', 'items' => [{ 'label' => 'A', 'url' => '/a' }] }],
                   'tools'   => [{ 'title' => 'Tools', 'items' => [{ 'label' => 'B', 'url' => '/b' }] }]
                 })

    assert_includes stg.send(:render_link_grid), 'A'
    refute_includes stg.send(:render_link_grid), 'B'
    assert_includes stg.send(:render_link_grid, 'tools'), 'B'
  end

  def test_render_link_grid_empty_when_unconfigured
    assert_includes stage([]).send(:render_link_grid), 'link-grid-empty'
  end

  # Links ändern sich nur mit der YAML — config_mtime ist der ganze ETag-Input,
  # kein Milan-Request nötig wie beim Widget-Board.
  def test_links_panel_answers_304_on_matching_etag
    stg = stage(panel_sections, 'links' => [{ 'title' => 'X', 'items' => [{ 'label' => 'A', 'url' => '/a' }] }])
    first = stg.send(:handle_panel, 'links', FakeRequest.new({}))
    etag  = first.headers['etag']
    refute_nil etag

    second = stg.send(:handle_panel, 'links', FakeRequest.new({ 'if-none-match' => etag }))
    assert_equal 304, second.status
  end
end
