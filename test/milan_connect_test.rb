# frozen_string_literal: true

# ruby test/milan_connect_test.rb
#
# /<agent>/<path> answers what milan answers at <path>: every method, the
# status, the body, and a stream as it is produced.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/milan'
require_relative '../lib/milan_double'
require_relative '../plugins/core/35-milan-connect'

ConnectRequest = Struct.new(:method, :headers, :body) do
  def read = body
end

class MilanConnectTest < Minitest::Test
  BUDGET = 0.2   # stands in for the router's timeout around `call`
  SSE    = { 'content-type' => 'text/event-stream; charset=UTF-8' }.freeze

  def setup
    @milan  = Dylan::MilanDouble.use
    @plugin = MilanConnectPlugin.new
  end

  def teardown
    Dylan::MilanDouble.reset
  end

  def read(response)
    body = +''
    while (chunk = response.body&.read)
      body << chunk
    end
    body
  end

  # Calls the plugin the way the router does: under the budget, body read
  # afterwards. Returns [status, headers, body], or :timeout.
  def call(path, method: 'GET', headers: {}, body: nil)
    result = nil
    Async do |task|
      request  = ConnectRequest.new(method, headers, body)
      response = task.with_timeout(BUDGET) { @plugin.call('dy.lan', path, request) }
      result = [response.status, response.headers, read(response)]
    rescue Async::TimeoutError
      result = :timeout
    end
    result
  end

  def test_matches_configured_agents_only
    assert @plugin.match?('dy.lan', '/mini/hello')
    refute @plugin.match?('dy.lan', '/nobody/hello')
    refute @plugin.match?('example.com', '/mini/hello')
  end

  # ── Calls ──────────────────────────────────────────────────────────────────

  def test_get_passes_status_and_body
    @milan.respond(path: '/hello/world', body: "hi\n")
    assert_equal [200, 'hi'], call('/mini/hello/world').values_at(0, 2)

    @milan.respond(path: '/sync', status: 422, body: 'rsync failed')
    assert_equal [422, 'rsync failed'], call('/mini/sync').values_at(0, 2)
    assert_equal [:get, 'mini', '/sync'], @milan.calls.last
  end

  def test_post_hands_the_body_and_its_headers_on
    status, = call('/mini/receive?x=1', method: 'POST', body: '{"a":1}',
                   headers: { 'content-type' => 'application/json',
                              'x-hub-signature-256' => 'sha256=abc',
                              'cookie' => 'not for milan' })
    assert_equal 200, status
    assert_equal [:post, 'mini', '/receive?x=1', '{"a":1}'], @milan.calls.last
    assert_equal [['content-type', 'application/json'], ['x-hub-signature-256', 'sha256=abc']],
                 @milan.sent_headers
  end

  def test_put_and_delete_are_forwarded_other_methods_refused
    call('/mini/widget/copy', method: 'PUT', body: 'text')
    assert_equal [:put, 'mini', '/widget/copy', 'text'], @milan.calls.last

    call('/mini/widget/copy', method: 'DELETE')
    assert_equal [:delete, 'mini', '/widget/copy'], @milan.calls.last

    status, _, body = call('/mini/hello', method: 'PATCH')
    assert_equal 405, status
    assert_includes body, 'PATCH'
    assert_equal 2, @milan.calls.size
  end

  def test_html_pages_get_the_agent_prefix_on_notes_links
    @milan.respond(path: '/album/x', headers: { 'content-type' => 'text/html; charset=utf-8' },
                   body: '<img src="/notes/alben/assets/a.jpg">')
    assert_equal '<img src="/mini/notes/alben/assets/a.jpg">', call('/mini/album/x').last
  end

  def test_unreachable_agent_is_a_503
    @milan.respond(error: Dylan::Milan::UnreachableError.new('mini', 'refused'))
    assert_equal [503, "Milan 'mini' unreachable"], call('/mini/hello').values_at(0, 2)
    assert_equal [503, "Milan 'mini' unreachable"], call('/mini/stream/backup').values_at(0, 2)
  end

  # ── Streams ────────────────────────────────────────────────────────────────

  def test_stream_passes_every_piece_and_the_content_type
    @milan.respond(path: '/stream/counter', headers: SSE,
                   chunks: ["data: one\n\n", "data: two\n\n", "event: done\ndata: \n\n"])
    status, headers, body = call('/mini/stream/counter')

    assert_equal 200, status
    assert_equal 'text/event-stream; charset=UTF-8', headers['content-type']
    assert_equal "data: one\n\ndata: two\n\nevent: done\ndata: \n\n", body
    assert_equal 1, @milan.closed_streams
  end

  # The case the route exists for: a script that runs longer than the budget.
  def test_stream_may_run_longer_than_the_budget
    slow = Enumerator.new do |out|
      out << "data: start\n\n"
      sleep(BUDGET * 3)
      out << "data: end\n\n"
    end
    @milan.respond(path: '/stream/backup', headers: SSE, chunks: slow)
    result = call('/mini/stream/backup')

    refute_equal :timeout, result
    assert_equal "data: start\n\ndata: end\n\n", result.last
  end

  # A refusal is known before the stream starts, so it keeps its status.
  def test_stream_refusal_keeps_milans_status
    @milan.respond(path: '/stream/nope', status: 404, body: "404 page not found\n")
    assert_equal [404, '404 page not found'], call('/mini/stream/nope').values_at(0, 2)
    assert_equal 1, @milan.closed_streams
  end

  def test_stream_takes_a_body_too
    @milan.respond(path: '/stream/import', headers: SSE, chunks: ["data: ok\n\n"])
    call('/mini/stream/import', method: 'POST', body: 'rows')
    assert_equal [:post, 'mini', '/stream/import', 'rows'], @milan.calls.last
  end

  # A caller that leaves closes the connection to milan, which is what lets
  # milan carry the script on as a background job.
  def test_a_reader_that_leaves_closes_the_stream_to_milan
    endless = Enumerator.new do |out|
      loop do
        out << "data: tick\n\n"
        sleep(0.02)
      end
    end
    @milan.respond(path: '/stream/tail', headers: SSE, chunks: endless)

    Sync do
      response = @plugin.call('dy.lan', '/mini/stream/tail', ConnectRequest.new('GET', {}, nil))
      response.body.read
      response.body.close
      sleep(0.1)
    end
    assert_equal 1, @milan.closed_streams
  end
end
