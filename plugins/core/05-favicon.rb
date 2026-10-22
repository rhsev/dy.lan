# frozen_string_literal: true

# Favicon Plugin — serves a small SVG as site icon and a PNG touch icon.
#
# Browsers request /favicon.ico once per domain; without a handler it would
# show up as a constant 404 in Dylan stats. SVG works in all modern desktop
# browsers as a favicon, is <300 bytes, and needs no binary handling.
#
# iOS ignores SVG for home screen bookmarks and asks for
# /apple-touch-icon.png instead; without one it draws the first letter of
# the page title. The PNG is rendered once at load time, so no binary file
# or image tool is needed.
#
# Design: Nord dark background (--n0) with a teal circle (--teal) —
# matches the `.dot` indicator in the Stage header.

require 'zlib'
require 'async/http/protocol/response'
require 'protocol/http/body/buffered'

class FaviconPlugin < Dylan::Plugin
  pattern(%r{^/(favicon\.ico|apple-touch-icon(-precomposed)?(-\d+x\d+)?\.png)$})
  timeout(1)

  SVG = <<~SVG.freeze
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
      <rect width="16" height="16" rx="3" fill="#2E3440"/>
      <circle cx="8" cy="8" r="3.5" fill="#88C0D0"/>
    </svg>
  SVG

  # Square without rounded corners; iOS applies its own mask.
  def self.touch_icon_png(size = 180, bg = [0x2E, 0x34, 0x40], fg = [0x88, 0xC0, 0xD0])
    center = size / 2.0
    radius = size * 3.5 / 16
    rows = Array.new(size) do |y|
      row = +"\x00"
      size.times do |x|
        dist  = Math.hypot(x + 0.5 - center, y + 0.5 - center)
        cover = (radius + 0.5 - dist).clamp(0.0, 1.0)
        row << bg.zip(fg).map { |b, f| (b + (f - b) * cover).round }.pack('C3')
      end
      row
    end
    chunk = lambda do |type, data|
      [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
    end
    "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR', [size, size, 8, 2, 0, 0, 0].pack('NNC5')) +
      chunk.call('IDAT', Zlib::Deflate.deflate(rows.join.b, Zlib::BEST_COMPRESSION)) +
      chunk.call('IEND', '')
  end

  PNG = touch_icon_png.freeze

  SVG_HEADERS = {
    'content-type'  => 'image/svg+xml',
    'cache-control' => 'public, max-age=86400'
  }.freeze

  PNG_HEADERS = {
    'content-type'  => 'image/png',
    'cache-control' => 'public, max-age=86400'
  }.freeze

  def call(host, path, request)
    headers, body = path.end_with?('.png') ? [PNG_HEADERS, PNG] : [SVG_HEADERS, SVG]
    Async::HTTP::Protocol::Response[200, headers,
      Protocol::HTTP::Body::Buffered.wrap(body)]
  end
end
