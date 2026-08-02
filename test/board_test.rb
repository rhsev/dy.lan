# frozen_string_literal: true

# ruby test/board_test.rb
#
# Deckt den Kachel-Teil von StageBase ab: Zuordnung Target → Kachel, discover,
# ttl-Ausgrauen und den ETag (der Normalfall eines Board-Polls ist ein 304).
# Kein HTTP-Server im Spiel — Milan wird gestubbt.

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

# Board-Instanz mit Config aus dem Test statt aus config/board.yaml.
class TestBoard < StageBase
  pattern    %r{^/board}
  url_prefix '/board'

  def initialize(config)
    super()
    @test_config = config
  end

  def config = @test_config
  def config_mtime = 0
end

FakeRequest = Struct.new(:headers)

class BoardTest < Minitest::Test
  def setup
    @now = Time.now.to_i
  end

  def board(sections, refresh: nil)
    cfg = { 'title' => 'Board', 'agent' => 'mini', 'sections' => sections }
    cfg['refresh'] = refresh if refresh
    TestBoard.new(cfg)
  end

  def widget(target, **fields)
    { 'target' => target, 'updated_at' => @now }.merge(fields.transform_keys(&:to_s))
  end

  # Ruft /widgets auf und gibt [status, headers, body] zurück.
  def get_widgets(board, widgets, headers = {})
    Dylan::Milan.stub_body = JSON.generate(widgets)
    response = board.send(:handle_widgets, FakeRequest.new(headers))
    body = +''
    while (chunk = response.body&.read)
      body << chunk
    end
    [response.status, response.headers, body]
  end

  def tile_section
    [{ 'title' => 'Läuft',
       'buttons' => [{ 'id' => 'copy', 'type' => 'widget', 'target' => 'copy', 'label' => 'Backup' }] }]
  end

  def test_tile_shows_pushed_state
    status, _, html = get_widgets(board(tile_section),
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
    _, _, html = get_widgets(board(tile_section), [])
    assert_includes html, 'data-target="copy"'
    assert_includes html, 'class="tile empty"'
  end

  # ttl abgelaufen = etwas, das laufen sollte, tut es nicht mehr. Muss als tot
  # erkennbar sein, sonst liest man alte Zahlen für aktuelle.
  def test_expired_ttl_greys_out
    stale = widget('copy', text: 'archive.zip', ttl: 60, updated_at: @now - 600)
    _, _, html = get_widgets(board(tile_section), [stale])
    assert_includes html, 'tile stale'

    fresh = widget('copy', text: 'archive.zip', ttl: 60)
    _, _, html = get_widgets(board(tile_section), [fresh])
    refute_includes html, 'tile stale'
  end

  # Ohne ttl ist „vor 4 Minuten" die normale und richtige Antwort, kein Fehler.
  def test_without_ttl_never_goes_stale
    old = widget('na', text: '3 Aufgaben', updated_at: @now - 86_400, color: '#34c759')
    sections = [{ 'title' => 'Zustand',
                  'buttons' => [{ 'id' => 'na', 'type' => 'widget', 'target' => 'na' }] }]
    _, _, html = get_widgets(board(sections), [old])

    refute_includes html, 'stale'
    assert_includes html, 'background: #34c759'
    assert_includes html, Time.at(@now - 86_400).strftime('%H:%M')
  end

  def test_discover_shows_unclaimed_targets
    sections = tile_section + [{ 'title' => 'Sonstiges', 'discover' => true }]
    _, _, html = get_widgets(board(sections),
                             [widget('copy', text: 'a'), widget('wegwerf', text: 'b')])

    assert_includes html, 'data-target="wegwerf"'
    assert_equal 1, html.scan('data-target="copy"').size, 'discover darf keine Kachel doppeln'
  end

  def test_ansi_and_escaping_in_tile_text
    _, _, html = get_widgets(board(tile_section), [widget('copy', text: "\e[32mok\e[0m <b>")])
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
    get_widgets(board(sections), %w[a b c].map { |t| widget(t, text: t) })
    assert_equal 1, calls
  end

  # ── ETag ───────────────────────────────────────────────────────────────────

  def test_unchanged_state_answers_304
    widgets = [widget('copy', text: 'archive.zip', progress: 10)]
    _, headers, = get_widgets(board(tile_section), widgets)
    etag = headers['etag']
    refute_nil etag

    status, _, body = get_widgets(board(tile_section), widgets, 'if-none-match' => etag)
    assert_equal 304, status
    assert_empty body
  end

  def test_new_push_changes_the_etag
    _, first, = get_widgets(board(tile_section), [widget('copy', text: 'a')])
    _, second, = get_widgets(board(tile_section),
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

    _, before, = get_widgets(board(tile_section), [fresh])
    _, after,  = get_widgets(board(tile_section), [expired])
    refute_equal before['etag'], after['etag']
  end

  # ── Board-Modus ────────────────────────────────────────────────────────────

  def test_refresh_only_for_instances_with_tiles
    assert_equal 3, board(tile_section).send(:widget_refresh)
    assert_equal 5, board(tile_section, refresh: 5).send(:widget_refresh)
    assert_equal 3, board([{ 'title' => 'x', 'discover' => true }]).send(:widget_refresh)

    plain = [{ 'title' => 'Actions',
               'buttons' => [{ 'id' => 'hello', 'type' => 'action', 'url' => '/mini/hello' }] }]
    assert_equal 0, board(plain).send(:widget_refresh),
                 'eine Stage ohne Kacheln bleibt eine Stage'
  end

  # Kacheln will man ansehen, nicht drücken: in der Sidebar haben sie nichts
  # verloren — und eine Section, die nur aus Kacheln besteht, auch keinen Titel.
  def test_widget_buttons_stay_out_of_the_sidebar
    sections = tile_section + [{ 'title' => 'Actions',
                                 'buttons' => [{ 'id' => 'hello', 'type' => 'action', 'label' => 'Hallo' }] }]
    sidebar = board(sections).send(:render_sidebar)

    refute_includes sidebar, 'Backup'
    refute_includes sidebar, 'Läuft'
    assert_includes sidebar, 'Hallo'
  end
end
