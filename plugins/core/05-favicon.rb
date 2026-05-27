# frozen_string_literal: true

# Favicon Plugin — serves a small SVG as site icon.
#
# Browsers request /favicon.ico once per domain; without a handler it would
# show up as a constant 404 in Dylan stats. SVG works in all modern desktop
# browsers as a favicon, is <300 bytes, and needs no binary handling.
#
# Design: Nord dark background (--n0) with a teal circle (--teal) —
# matches the `.dot` indicator in the Stage header.

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
