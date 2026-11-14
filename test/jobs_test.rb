# frozen_string_literal: true

# ruby test/jobs_test.rb
#
# Pins the cron hook that announces finished Milan jobs: a job is acknowledged
# once its message is out, and only then. No HTTP involved.

require 'minitest/autorun'
require 'async'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/milan'
require_relative '../plugins/core/60-jobs'

# Milan, config and ntfy from the test. Nothing here touches Dylan::Milan, so
# the file can share a process with the other tests and their stubs.
class TestJobs < JobsPlugin
  attr_reader :sent, :acks

  def initialize(config, pending, ntfy_ok: true)
    super()
    @test_config = config
    @pending     = pending
    @ntfy_ok     = ntfy_ok
    @sent        = []
    @acks        = []
  end

  def config = @test_config
  def agents = @pending.keys

  def pending(agent)
    answer = @pending.fetch(agent)
    raise answer if answer.is_a?(Exception)

    answer
  end

  def acknowledge(_agent, id) = @acks << id

  def notify(msg)
    return true unless config&.dig('ntfy', 'url')

    @sent << msg
    @ntfy_ok
  end
end

class JobsTest < Minitest::Test
  NTFY = { 'ntfy' => { 'url' => 'https://ntfy.example.org', 'topic' => 'jobs' } }.freeze
  DONE = { 'id' => 'sync_20261112_010203', 'script' => 'sync', 'exit_ok' => true }.freeze
  BAD  = { 'id' => 'copy 1', 'script' => 'copy', 'exit_ok' => false }.freeze

  # Returns [body, plugin].
  def check(pending, config = NTFY, **opts)
    plugin = TestJobs.new(config, pending, **opts)
    body = +''
    Sync do
      response = plugin.call('localhost', '/jobs/check', nil)
      while (chunk = response.body&.read)
        body << chunk
      end
    end
    [body, plugin]
  end

  def test_matches_only_its_route
    plugin = JobsPlugin.new
    assert plugin.match?('localhost', '/jobs/check')
    refute plugin.match?('localhost', '/jobs/check/x')
    refute plugin.match?('localhost', '/stage/jobs/check')
  end

  def test_nothing_pending
    body, plugin = check({ 'mini' => [], 'book' => [] })
    assert_equal 'no pending jobs', body
    assert_empty plugin.sent
    assert_empty plugin.acks
  end

  def test_job_is_announced_then_acknowledged
    body, plugin = check({ 'mini' => [DONE], 'book' => [BAD] })
    assert_equal ['✓ sync completed (mini)', '✗ copy failed (book)'], plugin.sent
    assert_equal "✓ sync completed (mini)\n✗ copy failed (book)", body
    assert_equal ['sync_20261112_010203', 'copy 1'], plugin.acks
  end

  # The case the move was made for: the message is lost, the job is not.
  def test_job_stays_pending_when_ntfy_fails
    body, plugin = check({ 'mini' => [DONE] }, ntfy_ok: false)
    assert_equal ['✓ sync completed (mini)'], plugin.sent
    assert_equal '✓ sync completed (mini) (ntfy failed, job stays pending)', body
    assert_empty plugin.acks
  end

  # Without ntfy there is nothing to send; jobs must not pile up as pending.
  def test_without_ntfy_jobs_are_acknowledged_silently
    body, plugin = check({ 'mini' => [DONE] }, {})
    assert_empty plugin.sent
    assert_equal '✓ sync completed (mini)', body
    assert_equal ['sync_20261112_010203'], plugin.acks
  end

  def test_one_agent_failing_does_not_stop_the_others
    body, plugin = check({ 'mini' => Dylan::Milan::UnreachableError.new('mini', 'Host is unreachable'),
                           'book' => [DONE] })
    assert_equal ['✓ sync completed (book)'], plugin.sent
    assert_match(/\Amini: error — .*unreachable.*\n✓ sync completed \(book\)\z/, body)
    assert_equal ['sync_20261112_010203'], plugin.acks
  end
end
