# frozen_string_literal: true

require 'async/http/protocol/response'
require 'protocol/http/body/buffered'

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
