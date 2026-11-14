# frozen_string_literal: true

# ruby test/whoami_test.rb
#
# Pins the identity check milan runs on start. The case it exists for: the
# MacBook bridged over the mini's Thunderbolt link arrives NATed with the
# mini's address, and the address-only lookup told it "you are mini".

require 'minitest/autorun'
require_relative '../lib/plugin'
require_relative '../lib/response'
require_relative '../lib/milan'
require_relative '../lib/milan_double'
require_relative '../plugins/core/95-whoami'

WhoamiAddress = Struct.new(:ip_address)
WhoamiRequest = Struct.new(:remote_address)

# milan.yaml section from the test instead of the file.
class TestWhoami < WhoamiPlugin
  def initialize(config)
    super()
    @test_config = config
  end

  def config = @test_config
end

class WhoamiTest < Minitest::Test
  MINI = '192.168.1.10'
  BOOK = '192.168.1.11'

  def setup
    Dylan::MilanDouble.use(agents: { 'mini' => "http://#{MINI}:8080", 'book' => "http://#{BOOK}:8080" })
  end

  def teardown
    Dylan::MilanDouble.reset
  end

  # Returns [status, body].
  def whoami(path, from:, config: {})
    response = TestWhoami.new(config).call('dy.lan', path, WhoamiRequest.new(WhoamiAddress.new(from)))
    body = +''
    while (chunk = response.body&.read)
      body << chunk
    end
    [response.status, body]
  end

  def test_name_matching_caller_is_confirmed
    assert_equal [200, "book (#{BOOK})"], whoami('/whoami?name=book', from: BOOK)
  end

  def test_name_is_url_decoded
    assert_equal [200, "book (#{BOOK})"], whoami('/whoami?name=b%6Fok', from: BOOK)
  end

  def test_unknown_name
    assert_equal [404, 'Unknown agent: ghost'], whoami('/whoami?name=ghost', from: BOOK)
  end

  # The bridged MacBook: claims book, arrives as the mini.
  def test_name_called_from_another_agents_address
    assert_equal [409, "book is registered at #{BOOK} but called from #{MINI} (registered as mini)"],
                 whoami('/whoami?name=book', from: MINI)
  end

  # The MacBook on the cable again, now with the mini's address listed for it:
  # it may start as book, wherever the WLAN switch happens to be.
  def test_name_called_from_an_also_from_address
    cable = { 'whoami_also_from' => { 'book' => [MINI] } }
    assert_equal [200, "book (#{MINI})"], whoami('/whoami?name=book', from: MINI, config: cable)
    assert_equal [200, "book (#{BOOK})"], whoami('/whoami?name=book', from: BOOK, config: cable)
  end

  # The list is per agent: it widens book's claim and nobody else's.
  def test_also_from_is_per_agent
    cable = { 'whoami_also_from' => { 'book' => [MINI] } }
    assert_equal [409, "mini is registered at #{MINI} but called from #{BOOK} (registered as book)"],
                 whoami('/whoami?name=mini', from: BOOK, config: cable)
    assert_equal [409, "book is registered at #{BOOK} but called from 192.168.1.50"],
                 whoami('/whoami?name=book', from: '192.168.1.50', config: cable)
  end

  # An agent listed with two addresses (WLAN and cable) may call from either,
  # and is found by either when it sends no name.
  def test_agent_with_two_addresses
    cable = '192.168.1.12'
    Dylan::MilanDouble.use(agents: { 'mini' => "http://#{MINI}:8080",
                                     'book' => ["http://#{BOOK}:8080", "http://#{cable}:8080"] })
    assert_equal [200, "book (#{BOOK})"], whoami('/whoami?name=book', from: BOOK)
    assert_equal [200, "book (#{cable})"], whoami('/whoami?name=book', from: cable)
    assert_equal [200, "book (#{cable})"], whoami('/whoami', from: cable)
    assert_equal [409, "book is registered at #{BOOK} or #{cable} but called from #{MINI} (registered as mini)"],
                 whoami('/whoami?name=book', from: MINI)
  end

  # A milan.yaml without the key, or none at all, changes nothing.
  def test_missing_config_keeps_the_strict_check
    assert_equal 409, whoami('/whoami?name=book', from: MINI, config: nil).first
  end

  def test_name_called_from_unregistered_address
    assert_equal [409, "book is registered at #{BOOK} but called from 192.168.1.50"],
                 whoami('/whoami?name=book', from: '192.168.1.50')
  end

  # milan.yaml may list an agent by name; the claim is checked against what
  # the name resolves to. localhost stands in for a LAN name here.
  def test_agent_registered_by_host_name
    Dylan::MilanDouble.use(agents: { 'mini' => 'http://localhost:8080', 'book' => "http://#{BOOK}:8080" })
    assert_equal [200, 'mini (127.0.0.1)'], whoami('/whoami?name=mini', from: '127.0.0.1')
    assert_equal [200, 'mini (127.0.0.1)'], whoami('/whoami', from: '127.0.0.1')
    status, body = whoami('/whoami?name=mini', from: BOOK)
    assert_equal 409, status
    assert_match(/\Amini is registered at localhost \(.*127\.0\.0\.1.*\) but called from #{Regexp.escape(BOOK)} \(registered as book\)\z/, body)
  end

  def test_agent_name_that_does_not_resolve
    Dylan::MilanDouble.use(agents: { 'mini' => 'http://no-such-host.invalid:8080' })
    assert_equal [409, "mini is registered at no-such-host.invalid (does not resolve) but called from #{MINI}"],
                 whoami('/whoami?name=mini', from: MINI)
  end

  # Old milan binaries send no name; they keep getting the address lookup.
  def test_without_name_identifies_by_address
    assert_equal [200, "mini (#{MINI})"], whoami('/whoami', from: MINI)
    assert_equal [404, 'Unknown caller: 192.168.1.50'], whoami('/whoami', from: '192.168.1.50')
  end

  # Raw non-ASCII is the one thing URI.decode_www_form refuses; a stray "%zz"
  # passes through and simply names no agent.
  def test_malformed_query
    assert_equal [400, 'Malformed query string'], whoami('/whoami?name=bück', from: BOOK)
    assert_equal [404, 'Unknown agent: %zz'], whoami('/whoami?name=%zz', from: BOOK)
  end

  def test_matches_with_query
    plugin = WhoamiPlugin.new
    assert plugin.match?('dy.lan', '/whoami')
    assert plugin.match?('dy.lan', '/whoami?name=book')
    refute plugin.match?('dy.lan', '/whoamix')
    refute plugin.match?('example.com', '/whoami?name=book')
  end
end
