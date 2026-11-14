# frozen_string_literal: true

require 'async/http/protocol/response'
require 'protocol/http/body/buffered'
require 'protocol/http/body/writable'
require 'async'

module Dylan
  # Response-Helper für gängige HTTP-Antworten
  # Uses HTTP Keep-Alive for better performance (managed by async-http)
  module Response
    # Redirect (302 Found)
    # @param location [String] Ziel-URL
    def self.redirect(location)
      Async::HTTP::Protocol::Response[
        302,
        { 'location' => location },
        []
      ]
    end

    # HTML Response
    # @param html [String] HTML-Content
    # @param status [Integer] HTTP-Status (default: 200)
    def self.html(html, status: 200)
      body = Protocol::HTTP::Body::Buffered.wrap(html)
      Async::HTTP::Protocol::Response[
        status,
        { 'content-type' => 'text/html; charset=UTF-8' },
        body
      ]
    end

    # Plain Text Response
    # @param text [String] Text-Content
    # @param status [Integer] HTTP-Status (default: 200)
    def self.text(text, status: 200)
      body = Protocol::HTTP::Body::Buffered.wrap(text)
      Async::HTTP::Protocol::Response[
        status,
        { 'content-type' => 'text/plain; charset=UTF-8' },
        body
      ]
    end

    # JSON Response
    # @param data [Hash, Array] JSON-Daten
    # @param status [Integer] HTTP-Status (default: 200)
    def self.json(data, status: 200)
      require 'json'
      json_string = JSON.generate(data)
      body = Protocol::HTTP::Body::Buffered.wrap(json_string)
      Async::HTTP::Protocol::Response[
        status,
        { 'content-type' => 'application/json; charset=UTF-8' },
        body
      ]
    end

    # ─── Answers that are filled after `call` has returned ──────────────────
    #
    # The router gives a plugin a time budget (Plugin.timeout) and cuts `call`
    # off when it runs out. Work that can take longer — a script on a Milan
    # agent, a slow backend — must not happen inside `call`. These three
    # helpers return the response at once and produce its content afterwards,
    # outside the budget. They close the body the right way and put a failure
    # where the reader will see it, so a plugin only writes the block.
    #
    # The price: the status is 200 before the content exists. A failure cannot
    # become a 502 any more; it arrives as content (`on_error`).

    # One piece of content, produced later. The block returns it.
    #
    #   Dylan::Response.deferred(on_error: ->(e) { "<p>#{e.message}</p>" }) do
    #     Dylan::Milan.get!('mini', '/album/urlaub').body
    #   end
    #
    # @param on_error [#call] receives the exception, returns the content to
    #   show instead (default: a plain "Error: ..." line)
    def self.deferred(content_type: 'text/html; charset=UTF-8', headers: {}, on_error: nil)
      on_error ||= ->(e) { "Error: #{e.message}" }
      stream(content_type: content_type, headers: headers,
             on_error: ->(e, body) { body.write(on_error.call(e).to_s) }) do |body|
        body.write(yield.to_s)
      end
    end

    # Content in pieces. The block receives the body and writes to it; when
    # the block ends, the response ends.
    #
    #   Dylan::Response.stream(content_type: 'text/plain; charset=UTF-8') do |body|
    #     Dylan::Milan.stream('mini', '/stream/backup') { |chunk| body.write(chunk) }
    #   end
    #
    # @param on_error [#call] receives the exception and the body
    def self.stream(content_type:, headers: {}, on_error: nil)
      body = Protocol::HTTP::Body::Writable.new
      Async do
        yield body
      rescue => e
        # A reader that has gone away makes the write below fail as well;
        # there is nobody left to tell.
        begin
          on_error ? on_error.call(e, body) : body.write("Error: #{e.message}")
        rescue StandardError
          nil
        end
      ensure
        # close_write, not close: `close` clears the queue and throws away
        # whatever the reader has not fetched yet, which is reliably the last
        # thing written.
        body.close_write rescue nil
      end

      Async::HTTP::Protocol::Response[
        200,
        { 'content-type' => content_type, 'cache-control' => 'no-cache' }.merge(headers),
        body
      ]
    end

    # Server-Sent Events. Like `stream`, with the SSE headers; a failure goes
    # out as a `stream_error` event followed by `done`, the two events the
    # Stage pad understands.
    #
    #   Dylan::Response.sse_stream { |body| Dylan::Milan.proxy_sse('mini', '/stream/x', body) }
    def self.sse_stream
      failed = lambda do |e, body|
        body.write("event: stream_error\ndata: #{e.message.to_s.gsub(/\s*\n\s*/, ' ')}\n\n")
        body.write("event: done\ndata: \n\n")
      end
      stream(content_type: 'text/event-stream; charset=UTF-8',
             headers: { 'x-accel-buffering' => 'no' }, on_error: failed) { |body| yield body }
    end

    # SSE, the manual form: prefer `sse_stream`, which does the task and the
    # closing for you.
    # Yields a Protocol::HTTP::Body::Writable; caller starts an Async task inside the block.
    # The block returns immediately; the response streams as chunks are written.
    #
    # Der Produzent beendet mit **close_write**, nicht mit `close`. `close` ruft
    # `@queue.clear` und wirft weg, was der Leser noch nicht abgeholt hat — und
    # da `write` nicht yieldet, ist das verlässlich das letzte geschriebene
    # Ereignis. Genau daran gingen `stream_error` und `done` verloren.
    # @yieldparam body [Protocol::HTTP::Body::Writable]
    def self.sse
      body = Protocol::HTTP::Body::Writable.new
      yield body
      Async::HTTP::Protocol::Response[
        200,
        {
          'content-type'      => 'text/event-stream; charset=UTF-8',
          'cache-control'     => 'no-cache',
          'x-accel-buffering' => 'no'
        },
        body
      ]
    end

    # 404 Not Found
    def self.not_found
      text("Not Found", status: 404)
    end

    # Error Response
    # @param status [Integer] HTTP-Status
    # @param message [String] Fehlermeldung
    def self.error(status, message)
      text(message, status: status)
    end
  end
end
