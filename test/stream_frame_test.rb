# frozen_string_literal: true

# ruby test/stream_frame_test.rb
#
# Die Eigenschaft, um die es geht: die iframe-Route des Albums liegt NICHT
# mehr im Zeitbudget des Plugins. Der Test stellt einen langsamen
# Milan hin, wickelt den Aufruf in genau den Timeout-Wrapper, den der Router
# benutzt (lib/router.rb), und prueft, dass die Antwort trotzdem kommt.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/static_assets'
require_relative '../lib/milan'
require_relative '../lib/milan_double'
require_relative '../lib/ansi'
require_relative '../plugins/core/55-stage'

class FrameStage < StageBase
  pattern    %r{^/stage}
  url_prefix '/stage'
  def config = { 'title' => 'Stage', 'sections' => [{ 'title' => 'Links', 'buttons' => [
    { 'id' => 'monitor', 'label' => 'monitor', 'type' => 'panel', 'panel' => 'frame', 'src' => '/monitor?x=<1>' },
    { 'id' => 'evil', 'label' => 'x', 'type' => 'panel', 'panel' => 'frame', 'src' => '//elsewhere.example/' }
  ] }] }
  def config_mtime = 0
end

class StreamFrameTest < Minitest::Test
  BUDGET = 0.4   # der 5s-Wrapper des Routers, nur schneller

  ALBUM = '<div class="album"></div>'

  def setup
    @milan = Dylan::MilanDouble.use
    @milan.respond(body: ALBUM)
  end

  def teardown
    Dylan::MilanDouble.reset
  end

  # Ruft die Route so auf, wie der Router es tut: call unter Timeout, Body erst
  # danach lesen. Liefert [antwort_kam, body].
  def through_router(path)
    result = nil
    Async do |task|
      response = task.with_timeout(BUDGET) { FrameStage.new.call(nil, path, nil) }
      body = +''
      while (chunk = response.body&.read)
        body << chunk
      end
      result = [true, body]
    rescue Async::TimeoutError
      result = [false, nil]
    end
    result
  end

  # Der Fall aus der Praxis: `register album` rendert beim ersten Oeffnen
  # Thumbnails, das dauert laenger als das Budget. Vorher kam hier
  # "Album error: execution expired".
  def test_slow_album_still_arrives
    @milan.respond(body: ALBUM, delay: BUDGET * 3)
    arrived, body = through_router('/stage/album/urlaub')

    assert arrived, 'die Antwort wurde vom Timeout des Routers gekillt'
    assert_includes body, 'class="album"'
  end

  # Bildpfade muessen weiter auf den Instance-Prefix gezogen werden.
  def test_asset_paths_get_the_prefix
    @milan.respond(body: %(<img src="/notes/alben/assets/images/a.jpg">))
    _, body = through_router('/stage/album/urlaub')

    assert_includes body, 'src="/stage/notes/alben/assets/images/a.jpg"'
  end

  # Der Frame-Panel bettet eine Seite desselben Hosts ein und nichts anderes.
  def test_frame_panel_embeds_a_local_path
    r = FrameStage.new.send(:handle_panel, 'monitor', nil)
    body = r.body.join
    assert_equal 200, r.status
    assert_includes body, '<iframe class="cb-panel" src="/monitor?x=&lt;1&gt;">'
    assert_equal 404, FrameStage.new.send(:handle_panel, 'evil', nil).status
  end

  # Der Status steht, bevor der Fehler bekannt ist — also gehoert die Meldung
  # in den Body, sonst zeigt das iframe eine leere Flaeche.
  def test_a_failing_milan_becomes_a_readable_frame
    @milan.respond(error: Dylan::Milan::UnreachableError.new('mini', 'connection refused'))
    arrived, body = through_router('/stage/album/urlaub')

    assert arrived
    assert_includes body, 'Album nicht erreichbar'
    assert_includes body, 'connection refused'
  end
end
