# frozen_string_literal: true

require 'async/http/client'
require 'async/http/endpoint'

module Dylan
  # Pool von wiederverwendbaren Async::HTTP::Client-Instanzen, gekeyed über die Basis-URL.
  #
  # **Bewusst pro Verwender instanziiert**, nicht global. So bleiben Lifecycle und
  # Invalidierung lokal (z.B. host-redirects.yaml-Reload schliesst nur seine
  # Proxy-Clients, nicht die Milan-Clients).
  #
  # Beispiel:
  #   @pool = Dylan::HttpPool.new
  #   client = @pool.for('http://192.168.1.118:8080')   # → persistent, gecacht
  #   response = client.get('/hello')
  #   @pool.clear!                                       # alle Verbindungen schliessen
  class HttpPool
    def initialize
      @clients = {}
    end

    # Liefert den gecachten Client für die URL oder erzeugt einen neuen.
    # URL ist Cache-Key — gleiche URL = gleicher Client = Connection-Reuse.
    def for(url)
      @clients[url] ||= Async::HTTP::Client.new(Async::HTTP::Endpoint.parse(url))
    end

    # Schliesst alle Clients und leert den Pool.
    # Aufrufen wenn sich die URL-Menge ändert (z.B. nach Config-Reload).
    def clear!
      @clients.each_value { |c| c.close rescue nil }
      @clients.clear
    end

    def size = @clients.size
  end
end
