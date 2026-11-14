# frozen_string_literal: true

# ruby test/agent_urls_test.rb
#
# An agent with more than one address: a MacBook that is on WLAN at one
# address and on the cable at another. Dylan asks the first that listens.

require 'minitest/autorun'
require_relative '../lib/milan'
require_relative '../lib/milan_double'

class AgentUrlsTest < Minitest::Test
  MINI  = 'http://192.168.1.10:8080'
  WLAN  = 'http://192.168.1.11:8080'
  CABLE = 'http://192.168.1.12:8080'

  def setup
    Dylan::MilanDouble.use(agents: { 'mini' => MINI, 'book' => [WLAN, CABLE] })
    Dylan::Milan.reset!
    @up     = [WLAN, CABLE]
    @probed = []
    Dylan::Milan.prober = lambda do |url|
      @probed << url
      @up.include?(url)
    end
  end

  def teardown
    Dylan::Milan.prober = nil
    Dylan::Milan.reset!
    Dylan::MilanDouble.reset
  end

  def current(name) = Dylan::Milan.send(:current_url, name)

  def test_urls_of_a_single_and_a_listed_agent
    assert_equal [MINI], Dylan::Milan.agent_urls('mini')
    assert_equal [WLAN, CABLE], Dylan::Milan.agent_urls('book')
    assert_equal WLAN, Dylan::Milan.agent_url('book')
    assert_empty Dylan::Milan.agent_urls('ghost')
    assert_nil Dylan::Milan.agent_url('ghost')
  end

  # One address is used as it always was: no connection test in front.
  def test_single_address_is_not_probed
    assert_equal MINI, current('mini')
    assert_empty @probed
  end

  def test_first_listening_address_wins
    assert_equal WLAN, current('book')
    @up = [CABLE]
    Dylan::Milan.reset!
    assert_equal CABLE, current('book')
  end

  # Within the TTL the answer is reused; after it the address in use is
  # asked first, so a book that stays on the cable costs one probe, not two.
  def test_answer_is_kept_and_rechecked_at_the_same_address_first
    @up = [CABLE]
    assert_equal CABLE, current('book')
    @probed.clear
    assert_equal CABLE, current('book')
    assert_empty @probed

    expire
    assert_equal CABLE, current('book')
    assert_equal [CABLE], @probed
  end

  def test_moves_to_the_other_address_when_the_current_one_stops_listening
    assert_equal WLAN, current('book')
    @up = [CABLE]
    expire
    _out, err = capture_io { assert_equal CABLE, current('book') }
    assert_match(/book is now at #{Regexp.escape(CABLE)}/, err)
  end

  def test_no_address_listening_is_unreachable
    @up = []
    error = assert_raises(Dylan::Milan::UnreachableError) { current('book') }
    assert_includes error.message, "#{WLAN} or #{CABLE}"
  end

  def test_unknown_agent
    assert_raises(Dylan::Milan::UnknownAgentError) { current('ghost') }
  end

  private

  def expire
    table = Dylan::Milan.instance_variable_get(:@current)
    table.each_value { |entry| entry[1] = Time.now - 60 }
  end
end
