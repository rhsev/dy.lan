# frozen_string_literal: true

# ruby test/helpers_test.rb
#
# The helpers a plugin author leans on: answers that are filled after `call`
# has returned, Milan calls that cannot forget the status, a time limit for
# one step, and the Milan double itself.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/milan'
require_relative '../lib/milan_double'

class HelpersTest < Minitest::Test
  BUDGET = 0.2   # stands in for the router's timeout around `call`

  def setup
    @milan = Dylan::MilanDouble.use
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

  # Calls the block the way the router calls a plugin: under the budget, with
  # the body read afterwards. Returns [headers, body], or :timeout.
  def through_router
    result = nil
    Async do |task|
      response = task.with_timeout(BUDGET) { yield }
      result = [response.headers, read(response)]
    rescue Async::TimeoutError
      result = :timeout
    end
    result
  end

  # ── Response.deferred ──────────────────────────────────────────────────────

  def test_deferred_content_may_take_longer_than_the_budget
    headers, body = through_router do
      Dylan::Response.deferred { sleep(BUDGET * 3); '<p>late</p>' }
    end
    assert_equal '<p>late</p>', body
    assert_equal 'text/html; charset=UTF-8', headers['content-type']
  end

  def test_deferred_failure_arrives_as_content
    _, body = through_router { Dylan::Response.deferred { raise 'boom' } }
    assert_equal 'Error: boom', body

    _, body = through_router do
      Dylan::Response.deferred(on_error: ->(e) { "<b>#{e.message}</b>" }) { raise 'boom' }
    end
    assert_equal '<b>boom</b>', body
  end

  # ── Response.stream / sse_stream ───────────────────────────────────────────

  def test_stream_delivers_every_piece_including_the_last
    _, body = through_router do
      Dylan::Response.stream(content_type: 'text/plain; charset=UTF-8') do |out|
        %w[one two last].each { |piece| out.write(piece) }
      end
    end
    assert_equal 'onetwolast', body
  end

  def test_sse_stream_reports_a_failure_as_events
    headers, body = through_router do
      Dylan::Response.sse_stream do |out|
        out.write("data: first\n\n")
        raise "two\nlines"
      end
    end
    assert_equal "data: first\n\nevent: stream_error\ndata: two lines\n\nevent: done\ndata: \n\n", body
    assert_equal 'text/event-stream; charset=UTF-8', headers['content-type']
  end

  # A browser that left makes every write fail. That must end the task
  # quietly, not as an unhandled exception in the log.
  def test_a_reader_that_left_does_not_raise
    Sync do
      response = Dylan::Response.stream(content_type: 'text/plain') do |out|
        sleep(0.05)
        out.write('nobody reads this')
      end
      response.body.close
      sleep(0.1)
    end
  end

  # ── Milan.get! / post! / rescued ───────────────────────────────────────────

  def test_get_bang_returns_a_good_answer
    @milan.respond(path: '/status', body: { 'ok' => true })
    assert_equal '{"ok":true}', Dylan::Milan.get!('mini', '/status').body
  end

  def test_get_bang_raises_on_the_agents_error
    @milan.respond(path: '/sync', status: 422, body: "rsync failed\n")
    error = assert_raises(Dylan::Milan::ErrorResponse) { Dylan::Milan.get!('mini', '/sync') }
    assert_equal 422, error.status
    assert_equal "rsync failed\n", error.body
    assert_equal 422, Dylan::Milan.get('mini', '/sync').status   # plain get leaves it to the caller
  end

  def test_post_bang_sends_the_body_and_checks_the_status
    Dylan::Milan.post!('mini', '/receive', 'payload')
    assert_equal 'payload', @milan.posted('/receive')

    @milan.respond(path: '/receive', status: 403, body: 'Invalid signature')
    assert_raises(Dylan::Milan::ErrorResponse) { Dylan::Milan.post!('mini', '/receive', 'payload') }
  end

  def test_rescued_turns_each_failure_into_its_response
    status_and_body = lambda do |&block|
      response = Dylan::Milan.rescued('mini', label: 'Notes', &block)
      [response.status, read(response)]
    end

    @milan.respond(path: '/gone', status: 404, body: "Note not found\n")
    assert_equal [404, 'Note not found'], status_and_body.call { Dylan::Milan.get!('mini', '/gone') }

    @milan.respond(path: '/down', error: Dylan::Milan::UnreachableError.new('mini', 'refused'))
    assert_equal [503, "Notes 'mini' unreachable"], status_and_body.call { Dylan::Milan.get!('mini', '/down') }

    assert_equal [503, 'Notes agent not configured: mini'],
                 status_and_body.call { Dylan::Milan.get!('nobody', '/x') }
  end

  # A Mac that is switched off answers the connect with EHOSTDOWN. Whatever
  # the network says, a plugin sees one thing: unreachable.
  def test_every_network_failure_is_unreachable
    Dylan::MilanDouble.reset
    client = Object.new
    Dylan::Milan.send(:pool).instance_variable_get(:@clients)['http://192.168.1.10:8080'] = client
    agents = Dylan::Milan.agents
    skip 'example milan.yaml has no agent at 192.168.1.10' unless agents['mini'] == 'http://192.168.1.10:8080'

    [Errno::EHOSTDOWN, Errno::ETIMEDOUT, Errno::ENETUNREACH, Errno::ECONNRESET, EOFError].each do |failure|
      client.define_singleton_method(:get) { |*_args| raise failure }
      assert_raises(Dylan::Milan::UnreachableError, failure.name) { Dylan::Milan.get('mini', '/health') }
    end
  ensure
    Dylan::Milan.reset!
  end

  # ── Plugin#within ──────────────────────────────────────────────────────────

  def test_within_limits_one_step
    plugin = Class.new(Dylan::Plugin) { abstract }.new
    outcome = nil
    Sync do
      plugin.within(0.05) { sleep(1) }
      outcome = :finished
    rescue Async::TimeoutError
      outcome = :cut_off
    end
    assert_equal :cut_off, outcome
    assert_equal 7, plugin.within(0.05) { 7 }   # no reactor: the block just runs
  end

  # ── MilanDouble ────────────────────────────────────────────────────────────

  def test_double_rules_last_one_wins_and_calls_are_recorded
    @milan.respond(body: 'any')
    @milan.respond(path: %r{^/album/}, agent: 'book', body: 'album')
    assert_equal 'any',   Dylan::Milan.get('mini', '/album/x').body
    assert_equal 'album', Dylan::Milan.get('book', '/album/x').body
    assert_equal [[:get, 'mini', '/album/x'], [:get, 'book', '/album/x']], @milan.calls
    assert_equal %w[mini book], Dylan::Milan.agents.keys
  end

  def test_double_streams_and_fails_like_the_client
    @milan.respond(path: '/stream/x', chunks: %w[a b])
    seen = []
    Dylan::Milan.stream('mini', '/stream/x') { |chunk| seen << chunk }
    assert_equal %w[a b], seen

    @milan.respond(path: '/stream/x', status: 404, body: 'no such script')
    error = assert_raises(Dylan::Milan::UnreachableError) { Dylan::Milan.stream('mini', '/stream/x') { nil } }
    assert_includes error.message, 'HTTP 404: no such script'
  end

  def test_after_reset_milan_is_itself_again
    Dylan::MilanDouble.reset
    refute_equal Dylan::MilanDouble::DEFAULT_AGENTS, Dylan::Milan.agents
  end
end
