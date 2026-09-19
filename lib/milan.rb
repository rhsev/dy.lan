# frozen_string_literal: true

require 'yaml'
require_relative 'http_pool'

module Dylan
  # Milan-Client-Bibliothek: zentrale Schnittstelle zu allen Milan-Agents.
  # Liest config/milan.yaml mit Hot-Reload und hält pro Agent einen wiederverwendbaren HTTP-Client.
  #
  # Erwartetes YAML-Schema:
  #   milan:
  #     enabled: true
  #     agents:
  #       mini: "http://192.168.1.118:8080"
  #       book: "http://192.168.1.188:8080"
  #
  # API:
  #   Dylan::Milan.agents                           # => { "mini" => "...", "book" => "..." }
  #   Dylan::Milan.agent_url("mini")                # => "http://..."
  #   Dylan::Milan.enabled?                         # => true/false
  #   Dylan::Milan.get(agent, path)                 # => Milan::Response (body in memory)
  #   Dylan::Milan.stream(agent, path) { |chunk| }  # => yields raw body chunks
  module Milan
    CONFIG_PATH = File.join(__dir__, '..', 'config', 'milan.yaml')
    CONFIG_CHECK_INTERVAL = 10  # Sekunden

    class UnreachableError < StandardError
      def initialize(agent, msg = nil)
        super("Milan agent '#{agent}' unreachable: #{msg}")
      end
    end

    class UnknownAgentError < StandardError
      def initialize(agent) = super("Unknown Milan agent: #{agent}")
    end

    Response = Struct.new(:status, :headers, :body) do
      def ok? = status >= 200 && status < 300
    end

    class << self
      # Block-Wrapper: führt Milan-Aufrufe aus, mappt geworfene Milan-Errors auf
      # passende Dylan::Response.error-Antworten. Für den Standard-Fall
      # "ein Milan-Call → eine HTTP-Antwort" (nicht für SSE oder Multi-Agent-Aggregation).
      #
      #   def handle_note_list(src)
      #     Dylan::Milan.rescued(notes_agent, label: 'Notes') do
      #       body = Dylan::Milan.get(notes_agent, "/notes/#{src}").body
      #       Dylan::Response.json(JSON.parse(body))
      #     end
      #   end
      def rescued(agent_name, label: 'Milan')
        yield
      rescue UnknownAgentError
        Dylan::Response.error(503, "#{label} agent not configured: #{agent_name}")
      rescue UnreachableError
        Dylan::Response.error(503, "#{label} '#{agent_name}' unreachable")
      rescue => e
        Dylan::Response.error(502, "#{label} error: #{e.message}")
      end

      def agents
        load_config
        @config&.dig('agents') || {}
      end

      def agent_url(name)
        agents[name.to_s]
      end

      def enabled?
        load_config
        !!(@config && @config['enabled'] != false)
      end

      # Sammelt Body in Memory. Für kleine/JSON-Antworten.
      # @raise [UnknownAgentError] wenn Agent nicht in Config
      # @raise [UnreachableError]  wenn Verbindung scheitert
      def get(agent_name, path)
        response = client_for(agent_name).get(path)
        Response.new(response.status, response.headers, response.read.to_s)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
        raise UnreachableError.new(agent_name, e.message)
      end

      # Streamt Body chunk-weise an den Block (low-level Variante).
      def stream(agent_name, path)
        response = client_for(agent_name).get(path)
        if response.status == 200
          begin
            response.body.each { |chunk| yield chunk }
          ensure
            response.body.close rescue nil  # Milan-Verbindung sauber freigeben
          end
        else
          raise UnreachableError.new(agent_name, "HTTP #{response.status}: #{response.read.to_s.strip}")
        end
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
        raise UnreachableError.new(agent_name, e.message)
      end

      # Proxyt einen Milan-Stream in einen offenen SSE-Body. Fehler gehen
      # als 'stream_error'-Event in den Stream (nicht als HTTP-Status, weil
      # die SSE-Response schon offen ist). Markiert das Ende mit 'done'.
      #
      # Caller behält Verantwortung für body.close (typischerweise via ensure).
      #
      #   Dylan::Response.sse do |body|
      #     Async do
      #       Dylan::Milan.proxy_sse(agent, path, body)
      #     ensure
      #       body.close
      #     end
      #   end
      def proxy_sse(agent_name, path, sse_body)
        stream(agent_name, path) { |chunk| sse_body.write(chunk) }
      rescue => e
        sse_body.write("event: stream_error\ndata: #{e.message}\n\n")
        sse_body.write("event: done\ndata: \n\n")
      end

      # Erzwingt das nächste Mal Reload (für Tests / manuelles Reset).
      def reset!
        @config = nil
        @config_loaded_at = nil
        @health_cache = nil
        @health_cache_at = nil
        pool.clear!
      end

      # Health-Status aller Agents. Gibt Map { agent_name => 'online'|'degraded'|'offline' } zurück.
      # Server-Cache mit kurzer TTL — verhindert dass mehrere Browser-Tabs/Polling-Loops
      # Milan überproportional belasten.
      HEALTH_CACHE_TTL = 2  # seconds (low: no polling, only checked on error)

      def health_check
        now = Time.now
        if @health_cache && @health_cache_at && (now - @health_cache_at) < HEALTH_CACHE_TTL
          return @health_cache
        end

        @health_cache = agents.each_with_object({}) do |(name, _url), result|
          result[name] = check_agent_health(name)
        end
        @health_cache_at = now
        @health_cache
      end

      private

      def check_agent_health(name)
        response = get(name, '/health')
        response.ok? ? 'online' : 'degraded'
      rescue UnreachableError
        'offline'
      rescue => e
        warn "[Milan health-check] #{name}: #{e.message}"
        'degraded'
      end

      def pool
        @pool ||= HttpPool.new
      end

      def load_config
        if @config && @config_loaded_at && (Time.now - @config_loaded_at) < CONFIG_CHECK_INTERVAL
          return @config
        end
        return @config unless File.exist?(CONFIG_PATH)

        new_config = (YAML.load_file(CONFIG_PATH) || {})['milan'] || {}  # leere Datei → nil
        new_config['agents'] ||= {}

        # Pool leeren, wenn sich Agent-URLs geändert haben
        pool.clear! if @config && @config['agents'] != new_config['agents']

        @config = new_config
        @config_loaded_at = Time.now
        @config
      rescue => e
        warn "[Milan] Config error: #{e.message}"
        @config
      end

      def client_for(name)
        url = agent_url(name) or raise UnknownAgentError.new(name)
        pool.for(url)
      end
    end
  end
end
