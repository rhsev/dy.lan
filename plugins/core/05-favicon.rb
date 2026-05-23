# frozen_string_literal: true

# Favicon Plugin — liefert ein kleines SVG als Site-Icon.
#
# Browser fragen jede Domain einmal nach /favicon.ico, der 404 davon würde sonst
# in den Dylan-Stats als ständiger Fehler auftauchen. SVG funktioniert in allen
# modernen Browsern als Favicon, ist <300 Bytes und braucht kein Binary-Handling.
#
# Design: Nord-dunkelgrauer Hintergrund (--n0) mit blauem Punkt (--blue) —
# matched den `.dot` Indikator im Stage-Header.

require 'async/http/protocol/response'
require 'protocol/http/body/buffered'

class FaviconPlugin < Dylan::Plugin
  pattern(%r{^/favicon\.ico$})
  timeout(1)

  SVG = <<~SVG.freeze
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
      <rect width="16" height="16" rx="3" fill="#2E3440"/>
      <circle cx="8" cy="8" r="3.5" fill="#88C0D0"/>
    </svg>
  SVG

  HEADERS = {
    'content-type'  => 'image/svg+xml',
    'cache-control' => 'public, max-age=86400'
  }.freeze

  def call(host, path, request)
    Async::HTTP::Protocol::Response[200, HEADERS,
      Protocol::HTTP::Body::Buffered.wrap(SVG)]
  end
end
