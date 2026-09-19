# frozen_string_literal: true

# ruby test/stream_frame_test.rb
#
# Die Eigenschaft, um die es geht: die beiden iframe-Routen (Album, Pinboard)
# liegen NICHT mehr im Zeitbudget des Plugins. Der Test stellt einen langsamen
# Milan hin, wickelt den Aufruf in genau den Timeout-Wrapper, den der Router
# benutzt (lib/router.rb), und prueft, dass die Antwort trotzdem kommt.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/static_assets'
require_relative '../lib/milan'
require_relative '../lib/ansi'
require_relative '../plugins/core/55-stage'

# Milan, der so lange braucht, wie der Test es verlangt.
module SlowMilanStub
  attr_accessor :stub_delay, :stub_body, :stub_error

  def get(_agent, _path)
    Async::Task.current.sleep(stub_delay.to_f) if stub_delay
    raise stub_error if stub_error

    Dylan::Milan::Response.new(200, {}, stub_body.to_s)
  end
end
Dylan::Milan.singleton_class.prepend(SlowMilanStub)

class FrameStage < StageBase
  pattern    %r{^/stage}
  url_prefix '/stage'
  def config = { 'title' => 'Stage', 'sections' => [] }
  def config_mtime = 0
end

class StreamFrameTest < Minitest::Test
  BUDGET = 0.4   # der 5s-Wrapper des Routers, nur schneller

  def setup
    Dylan::Milan.stub_delay = nil
    Dylan::Milan.stub_error = nil
    Dylan::Milan.stub_body  = '<div class="album"></div>'
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
    Dylan::Milan.stub_delay = BUDGET * 3
    arrived, body = through_router('/stage/album/urlaub')

    assert arrived, 'die Antwort wurde vom Timeout des Routers gekillt'
    assert_includes body, 'class="album"'
  end

  def test_slow_pinboard_still_arrives
    Dylan::Milan.stub_delay = BUDGET * 3
    Dylan::Milan.stub_body  = '<div class="list"></div>'
    arrived, body = through_router('/stage/bookmarks/all')

    assert arrived
    assert_includes body, 'class="list"'
  end

  # Bildpfade muessen weiter auf den Instance-Prefix gezogen werden.
  def test_asset_paths_get_the_prefix
    Dylan::Milan.stub_body = %(<img src="/notes/alben/assets/images/a.jpg">)
    _, body = through_router('/stage/album/urlaub')

    assert_includes body, 'src="/stage/notes/alben/assets/images/a.jpg"'
  end

  # Der Status steht, bevor der Fehler bekannt ist — also gehoert die Meldung
  # in den Body, sonst zeigt das iframe eine leere Flaeche.
  def test_a_failing_milan_becomes_a_readable_frame
    Dylan::Milan.stub_error = Dylan::Milan::UnreachableError.new('mini', 'connection refused')
    arrived, body = through_router('/stage/album/urlaub')

    assert arrived
    assert_includes body, 'Album nicht erreichbar'
    assert_includes body, 'connection refused'
  end
end
