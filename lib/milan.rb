# frozen_string_literal: true

require 'yaml'
require 'async'
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
  #   Dylan::Milan.get!(agent, path)                # => Milan::Response (body in memory); raises on non-2xx
  #   Dylan::Milan.post!(agent, path, body)         # => same; the body goes to the script's stdin
  #   Dylan::Milan.get / .post                      # => same without the check: the status is yours to read
  #   Dylan::Milan.stream(agent, path) { |chunk| }  # => yields raw body chunks
  module Milan
    CONFIG_PATH = File.join(__dir__, '..', 'config', 'milan.yaml')
    CONFIG_CHECK_INTERVAL = 10  # Sekunden

    # What a connection to an agent can fail with. All of it means the same to
    # a plugin: the agent is not there. The list used to stop after the first
    # two, and a Mac that was switched off (EHOSTDOWN) came through as a raw
    # exception and a 500.
    NETWORK_ERRORS = [
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::EHOSTDOWN, Errno::ENETUNREACH,
      Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, SocketError, EOFError
    ].freeze

    class UnreachableError < StandardError
      def initialize(agent, msg = nil)
        super("Milan agent '#{agent}' unreachable: #{msg}")
      end
    end

    class UnknownAgentError < StandardError
      def initialize(agent) = super("Unknown Milan agent: #{agent}")
    end

    # The agent answered, but not with a 2xx: script failed (422), unknown
    # script or note (404), blocked (403). Raised by get!/post!.
    class ErrorResponse < StandardError
      attr_reader :agent, :status, :body

      def initialize(agent, status, body)
        @agent  = agent
        @status = status
        @body   = body.to_s
        super("Milan agent '#{agent}' answered #{status}: #{@body.strip[0, 200]}")
      end
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
      # The agent's own verdict, from get!/post!: its status and its words.
      rescue ErrorResponse => e
        Dylan::Response.error(e.status, e.body.strip)
      # The router aborts plugin.call when the plugin's time budget runs out
      # (lib/router.rb), and Async::TimeoutError is a StandardError — so it used
      # to land in the generic branch below and come out as
      # "Album error: execution expired", blaming the agent for a deadline it
      # never saw. Say whose deadline it was.
      rescue Async::TimeoutError
        Dylan::Response.error(504, "#{label} exceeded the plugin's time budget (the agent may still be working)")
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
      rescue *NETWORK_ERRORS => e
        raise UnreachableError.new(agent_name, e.message)
      end

      # POSTs body; milan hands it to the script on stdin.
      # @raise [UnknownAgentError] wenn Agent nicht in Config
      # @raise [UnreachableError]  wenn Verbindung scheitert
      def post(agent_name, path, body, content_type: 'text/plain; charset=utf-8')
        response = client_for(agent_name).post(path, [['content-type', content_type]], [body.to_s])
        Response.new(response.status, response.headers, response.read.to_s)
      rescue *NETWORK_ERRORS => e
        raise UnreachableError.new(agent_name, e.message)
      end

      # get and post hand back whatever the agent answered, a 404 or 422
      # included, and a caller that forgets `ok?` passes an error text on as if
      # it were the result. These two raise ErrorResponse instead; inside
      # `rescued` that becomes a response with the agent's status and message.
      # Use them unless the status itself is what you are after.
      def get!(agent_name, path)
        checked(agent_name, get(agent_name, path))
      end

      def post!(agent_name, path, body, **options)
        checked(agent_name, post(agent_name, path, body, **options))
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
      rescue *NETWORK_ERRORS => e
        raise UnreachableError.new(agent_name, e.message)
      end

      # Proxyt einen Milan-Stream in einen offenen SSE-Body. Fehler gehen
      # als 'stream_error'-Event in den Stream (nicht als HTTP-Status, weil
      # die SSE-Response schon offen ist). Markiert das Ende mit 'done'.
      #
      # Zusammen mit Dylan::Response.sse_stream, das Task und Abschluss
      # übernimmt:
      #
      #   Dylan::Response.sse_stream { |body| Dylan::Milan.proxy_sse(agent, path, body) }
      def proxy_sse(agent_name, path, sse_body)
        stream(agent_name, path) { |chunk| sse_body.write(chunk) }
      rescue => e
        sse_body.write("event: stream_error\ndata: #{e.message}\n\n")
        sse_body.write("event: done\ndata: \n\n")
      end

      # A page from milan links its files as /notes/…, a route of milan's own.
      # Behind Dylan they need the prefix under which Dylan forwards to that
      # agent ("/mini", "/stage"), or the browser asks Dylan for a route it
      # does not have.
      def prefix_notes_links(html, prefix)
        html.gsub(%r{\b(src|href)="/notes/}) { %(#{Regexp.last_match(1)}="#{prefix}/notes/) }
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
      # A sleeping Mac does not refuse, it drops silently. Without a limit of
      # its own, one absent agent used up the caller's whole time budget.
      HEALTH_TIMEOUT   = 2  # seconds per agent

      def health_check
        now = Time.now
        if @health_cache && @health_cache_at && (now - @health_cache_at) < HEALTH_CACHE_TTL
          return @health_cache
        end

        # All agents at once: the answer takes as long as the slowest agent,
        # not as long as all of them together.
        names = agents.keys
        tasks = names.map { |name| Async { check_agent_health(name) } }
        @health_cache = names.zip(tasks.map(&:wait)).to_h
        @health_cache_at = now
        @health_cache
      end

      private

      def checked(agent_name, response)
        raise ErrorResponse.new(agent_name, response.status, response.body) unless response.ok?

        response
      end

      def check_agent_health(name)
        response = Async::Task.current.with_timeout(HEALTH_TIMEOUT) { get(name, '/health') }
        response.ok? ? 'online' : 'degraded'
      rescue UnreachableError, Async::TimeoutError
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
