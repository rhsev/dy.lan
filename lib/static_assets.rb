# frozen_string_literal: true

require_relative 'response'

module Dylan
  # Static asset server for plugin frontend bundles.
  #
  # Serves files from a directory with two-level caching:
  #   - **Server memory cache**: file is read once and stored with its mtime.
  #     On subsequent requests with unchanged mtime → no file read.
  #     On changed mtime → re-read (edits are live without restart).
  #   - **Browser ETag cache**: ETag = mtime epoch. `cache-control: no-cache`
  #     forces revalidation; on match → 304 (no body, ~100 bytes).
  #     Font files (font/*) use `immutable` instead — no revalidation needed.
  #
  # Usage in a plugin:
  #
  #   ASSET_TYPES = {
  #     'style.css' => 'text/css; charset=UTF-8',
  #     'app.js'    => 'application/javascript; charset=UTF-8'
  #   }.freeze
  #
  #   def initialize
  #     super
  #     @assets = Dylan::StaticAssets.new(dir: File.join(__dir__, 'mything'),
  #                                       types: ASSET_TYPES)
  #   end
  #
  #   def call(host, path, request)
  #     case path
  #     when %r{^/mything/assets/([\w.-]+)$}
  #       @assets.serve(Regexp.last_match(1), request)
  #     # ...
  #     end
  #   end
  #
  # `types` doubles as a whitelist — filenames not listed return 404
  # regardless of whether they exist on disk.
  class StaticAssets
    def initialize(dir:, types:)
      @dir   = dir
      @types = types
      @cache = {}
    end

    # Returns an Async::HTTP response:
    #   - 200 + body if new or changed
    #   - 304 + empty body if browser ETag matches
    #   - 404 if file is not in the types whitelist or does not exist
    def serve(name, request)
      ct = @types[name]
      return Dylan::Response.error(404, "Asset '#{name}' not found") unless ct

      path  = File.join(@dir, name)
      mtime = File.mtime(path)
      etag  = %("#{mtime.to_i}")

      # headers[] can be a string or array — flatten defensively
      inm = Array(request.headers['if-none-match']).flatten.join(',')
      if !inm.empty? && (inm == '*' || inm.include?(etag))
        return Async::HTTP::Protocol::Response[304, { 'etag' => etag }, []]
      end

      entry = @cache[name]
      if entry.nil? || entry[:mtime] != mtime
        @cache[name] = { body: File.binread(path), mtime: mtime }
      end

      cache_control = ct.start_with?('font/') ? 'public, max-age=31536000, immutable' : 'no-cache'
      body = Protocol::HTTP::Body::Buffered.wrap(@cache[name][:body])
      Async::HTTP::Protocol::Response[200,
        { 'content-type' => ct, 'etag' => etag, 'cache-control' => cache_control },
        body]
    rescue Errno::ENOENT
      Dylan::Response.error(404, "Asset '#{name}' not found")
    end
  end
end
