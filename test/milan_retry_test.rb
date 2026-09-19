# frozen_string_literal: true

# ruby test/milan_retry_test.rb
#
# Deckt den Retry in Dylan::Milan.get ab: eine tote gepoolte Verbindung kostet
# einen Versuch und wird dann auf einem frischen Client erfolgreich wiederholt;
# ein abgelehnter Verbindungsaufbau wird nicht wiederholt. Kein echtes HTTP —
# der Pool liefert Fake-Clients.

require 'minitest/autorun'
require_relative '../lib/milan'

# Client, der die ersten `fail_times` Aufrufe mit `error` quittiert.
class FakeClient
  attr_reader :calls

  def initialize(fail_times: 0, error: EOFError.new('closed'))
    @fail_times = fail_times
    @error = error
    @calls = 0
  end

  def get(_path)
    @calls += 1
    raise @error if @calls <= @fail_times
    FakeResponse.new(200, {})
  end

  def close; end
end

# Nachbildung der async-http-Antwort, soweit Milan.get sie anfasst.
FakeResponse = Struct.new(:status, :headers) do
  def read = 'ok'
end

# Pool, der eine vorgegebene Client-Folge ausgibt — ein discard rückt den
# nächsten Client vor, genau wie ein echter Pool eine neue Verbindung öffnet.
class FakePool
  attr_reader :discards

  def initialize(clients)
    @clients = clients
    @discards = 0
  end

  def for(_url) = @clients.first
  def discard(_url)
    @discards += 1
    @clients.shift
    true
  end
end

module Dylan
  module Milan
    class << self
      attr_writer :test_pool
      def pool = @test_pool
      def agents = { 'mini' => 'http://127.0.0.1:8080' }
    end
  end
end

class MilanRetryTest < Minitest::Test
  def teardown
    Dylan::Milan.test_pool = nil
  end

  # Der Fall nach jedem Milan-Neustart: der gepoolte Socket ist tot, der Agent
  # läuft. Vorher kam das als 502 heraus.
  def test_dead_pooled_connection_is_retried_on_a_fresh_client
    dead  = FakeClient.new(fail_times: 1)
    fresh = FakeClient.new
    pool  = FakePool.new([dead, fresh])
    Dylan::Milan.test_pool = pool

    response = Dylan::Milan.get('mini', '/health')

    assert_equal 200, response.status
    assert_equal 'ok', response.body
    assert_equal 1, pool.discards, 'der tote Client muss aus dem Pool fliegen'
    assert_equal 1, fresh.calls
  end

  # Zweimal derselbe Fehler heisst: es lag nicht an der Verbindung.
  def test_gives_up_after_one_retry
    pool = FakePool.new([FakeClient.new(fail_times: 9), FakeClient.new(fail_times: 9)])
    Dylan::Milan.test_pool = pool

    assert_raises(Dylan::Milan::UnreachableError) { Dylan::Milan.get('mini', '/health') }
    assert_equal 1, pool.discards, 'genau ein Retry, nicht mehr'
  end

  # Ein abgelehnter Verbindungsaufbau ist kein totes Keep-Alive — sofort melden,
  # statt die Wartezeit zu verdoppeln.
  def test_connection_refused_is_not_retried
    pool = FakePool.new([FakeClient.new(fail_times: 9, error: Errno::ECONNREFUSED.new)])
    Dylan::Milan.test_pool = pool

    assert_raises(Dylan::Milan::UnreachableError) { Dylan::Milan.get('mini', '/health') }
    assert_equal 0, pool.discards
  end

  def test_unknown_agent_is_not_retried
    pool = FakePool.new([FakeClient.new])
    Dylan::Milan.test_pool = pool

    assert_raises(Dylan::Milan::UnknownAgentError) { Dylan::Milan.get('nobody', '/health') }
    assert_equal 0, pool.discards
  end
end
