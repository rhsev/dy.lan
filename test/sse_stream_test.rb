# frozen_string_literal: true

# ruby test/sse_stream_test.rb
#
# Nagelt den Fehlerpfad des SSE-Proxys fest. Der Bug, den das verhindert: der
# Produzent schrieb stream_error und done direkt hintereinander und lief dann
# in `ensure body.close`, das die Queue leert — write yieldet nicht, der Leser
# war also nie dran. Der Browser sah nur EOF, und app.js meldete einen
# gescheiterten Lauf als sauber beendet.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/static_assets'
require_relative '../lib/milan'
require_relative '../lib/milan_double'
require_relative '../lib/ansi'
require_relative '../plugins/core/55-stage'

class SseStage < StageBase
  pattern    %r{^/stage}
  url_prefix '/stage'

  STREAM_BUTTON = { 'id' => 'counter', 'type' => 'stream', 'url' => '/mini/stream/counter' }.freeze

  def config = { 'title' => 'Stage', 'sections' => [{ 'buttons' => [STREAM_BUTTON] }] }
  def config_mtime = 0
end

class SseStreamTest < Minitest::Test
  def setup
    @milan = Dylan::MilanDouble.use
  end

  def teardown
    Dylan::MilanDouble.reset
  end

  def run_stream
    out = nil
    Async do
      response = SseStage.new.call(nil, '/stage/run/counter', nil)
      body = +''
      while (chunk = response.body&.read)
        body << chunk
      end
      out = body
    end
    out
  end

  # Der Fall, der stumm blieb: milan nicht erreichbar. Die Meldung muss beim
  # Leser ankommen, sonst zeigt das Pad einen erfolgreichen Lauf an.
  def test_a_failing_stream_delivers_its_error
    @milan.respond(error: Dylan::Milan::UnreachableError.new('mini', 'connection refused'))
    body = run_stream

    assert_includes body, 'event: stream_error'
    assert_includes body, 'connection refused'
  end

  # done ist das Ereignis unmittelbar vor dem Schliessen — der empfindlichste
  # Chunk ueberhaupt.
  def test_the_final_done_event_survives
    @milan.respond(error: Dylan::Milan::UnreachableError.new('mini', 'nope'))

    assert_includes run_stream, 'event: done'
  end

  # Und der Normalfall reicht weiter durch, ohne dass der letzte Chunk fehlt.
  def test_chunks_pass_through_including_the_last
    @milan.respond(chunks: ["data: eins\n\n", "data: zwei\n\n", "data: letzte\n\n"])
    body = run_stream

    assert_includes body, 'data: eins'
    assert_includes body, 'data: letzte'
  end

  def test_unknown_stream_id_is_a_404
    response = SseStage.new.call(nil, '/stage/run/gibtsnicht', nil)

    assert_equal 404, response.status
  end
end
