# frozen_string_literal: true

# Favicon Plugin — serves a small SVG as site icon plus an apple-touch-icon PNG.
#
# Browsers request /favicon.ico once per domain; without a handler it would
# show up as a constant 404 in Dylan stats. SVG works in all modern desktop
# browsers as a favicon, is <300 bytes, and needs no binary handling.
#
# iOS Safari requires a separate apple-touch-icon (PNG, 180×180) for the
# bookmarks/favorites shelf — SVG favicons are ignored there.
#
# Design: Nord dark background (--n0) with a teal circle (--teal) —
# matches the `.dot` indicator in the Stage header.

require 'base64'
require 'async/http/protocol/response'
require 'protocol/http/body/buffered'

class FaviconPlugin < Dylan::Plugin
  pattern(%r{^/(favicon\.ico|apple-touch-icon\.png)$})
  timeout(1)

  SVG = <<~SVG.freeze
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
      <rect width="16" height="16" rx="3" fill="#2E3440"/>
      <circle cx="8" cy="8" r="3.5" fill="#88C0D0"/>
    </svg>
  SVG

  # 180×180 PNG — Nord dark bg (#2E3440) + teal circle (#88C0D0, r=63)
  TOUCH_ICON_B64 = 'iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAIAAACyr5FlAAACl0lEQVR42u3d' \
    'wU1DQRBEwYmIEwEQHmERAiGZADggAd7u2ZJeBD0l3/x3Xl7fpG8bEwgOwSE4BIfgEByCQ3AIDsEh' \
    'wSE4BIfgEByCQ3AIDsEhOCQ4BIfgEByCQ3Dk9f7xaYRLcXzd/vfBAQQoS3H8K4h7oAwTlCzHEcJi' \
    'GZHBApGFOMJZLCAyWCCyBEcpi1IigwUi3TiWyWjxMWTwUYljMYsKIkMGH2U4rpIR62PI4KMDx7Us' \
    'MokMGXyk4wAi0MeQwQcccBTigCDWx5DBRyIOhw/3MWTwAQccJTgcu8LHkMFHCg4HLvIBBxwZOJy2' \
    'ywcccATgcNQ6H3DAcRqHczb6gAOOozgcstQHHHCcw+GEvT7ggOMQDser9gEHHHDAEYXD2dp9wAEH' \
    'HHDAAUcBDgdb4AMOOOCAAw440nE41Q4fcMABBxxwwAGH4BAcgkNwwAEHHHDAAQcZfPjlIAMOOOAQ' \
    'HIJDcAgOwQEHHHDAAQcccMDhfytkwCE4BId24+DD9znggAMOOOCAw3dIyYADDjjg8GqCnioDDji8' \
    '1EQGHHB4HVLPkAEHHF6kJgMOOFpx8NElAw44YnDwUSQDDjiScPDRIuMMDj4qZBzDwUe+DDjgiMTB' \
    'R7iMwzj4SJZxHgcfsTIicPCRKQMOOOJx8BEoIwgHH2kysnDwESUjDsflRNIOkYjjTh+BVwjFcZuP' \
    'zBPk4rjHR+z+0TjWEwlfvgDHVh/5s3fg2OejYvMaHGuIFK1dhqOaSN3OlTjqiJQuXIyjgkj1tvU4' \
    'YoksWHUJjioia/ZcheOskn0z7sTxNCi7p9uP48+h3DPXXTh+oscIcAgOwSE4BIfgEByCQ3AIDgkO' \
    'wSE4BIfgEByCQ3AIDsEhOCQ4BIfgEByCQ2E9AK5+MQhCojycAAAAAElFTkSuQmCC'
  TOUCH_ICON_PNG = Base64.strict_decode64(TOUCH_ICON_B64.gsub("\n", '')).freeze

  SVG_HEADERS = {
    'content-type'  => 'image/svg+xml',
    'cache-control' => 'public, max-age=86400'
  }.freeze

  PNG_HEADERS = {
    'content-type'  => 'image/png',
    'cache-control' => 'public, max-age=86400'
  }.freeze

  def call(host, path, request)
    if path == '/apple-touch-icon.png'
      Async::HTTP::Protocol::Response[200, PNG_HEADERS,
        Protocol::HTTP::Body::Buffered.wrap(TOUCH_ICON_PNG)]
    else
      Async::HTTP::Protocol::Response[200, SVG_HEADERS,
        Protocol::HTTP::Body::Buffered.wrap(SVG)]
    end
  end
end
