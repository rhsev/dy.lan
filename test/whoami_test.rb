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
require_relative '../plugins/core/95-whoami'

# Agents from the test instead of config/milan.yaml.
module AgentsStub
  attr_accessor :stub_agents

  def agents = stub_agents || super
end
Dylan::Milan.singleton_class.prepend(AgentsStub)

WhoamiAddress = Struct.new(:ip_address)
WhoamiRequest = Struct.new(:remote_address)

class WhoamiTest < Minitest::Test
  MINI = '192.168.1.118'
  BOOK = '192.168.1.187'

  def setup
    Dylan::Milan.stub_agents = { 'mini' => "http://#{MINI}:8080", 'book' => "http://#{BOOK}:8080" }
  end

  def teardown
    Dylan::Milan.stub_agents = nil
  end

  # Returns [status, body].
  def whoami(path, from:)
    response = WhoamiPlugin.new.call('dy.lan', path, WhoamiRequest.new(WhoamiAddress.new(from)))
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

  def test_name_called_from_unregistered_address
    assert_equal [409, "book is registered at #{BOOK} but called from 192.168.1.50"],
                 whoami('/whoami?name=book', from: '192.168.1.50')
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
