# frozen_string_literal: true

require_relative 'response'

module Dylan
  # Static-Asset-Server für Plugin-Frontend-Bundles.
  #
  # Liefert Dateien aus einem Verzeichnis mit zweistufigem Caching:
  #   - **Server-Memory-Cache**: Datei wird gelesen, mit mtime-Marker abgelegt.
  #     Bei nächstem Request mit unverändertem mtime → kein File-Read.
  #     Bei geändertem mtime → neu einlesen (Edits live wirksam ohne Restart).
  #   - **Browser-ETag-Cache**: ETag = mtime epoch. `cache-control: no-cache`
  #     zwingt den Browser zu revalidieren; bei Match → 304 (kein Body, ~100 Byte).
  #
  # Verwendung im Plugin:
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
  # `types` ist gleichzeitig eine Whitelist — Dateinamen die nicht enthalten
  # sind kriegen 404, unabhängig davon ob sie im Verzeichnis existieren.
  class StaticAssets
    def initialize(dir:, types:)
      @dir   = dir
      @types = types
      @cache = {}
    end

    # Returnt eine Async::HTTP-Response:
    #   - 200 + Body wenn neu/geändert
    #   - 304 + leerer Body wenn Browser-ETag aktuell ist
    #   - 404 wenn Datei nicht in der Types-Whitelist oder nicht vorhanden
    def serve(name, request)
      ct = @types[name]
      return Dylan::Response.error(404, "Asset '#{name}' not found") unless ct

      path  = File.join(@dir, name)
      mtime = File.mtime(path)
      etag  = %("#{mtime.to_i}")

      # request.headers[] kann String oder Array sein — defensiv flatten
      inm = Array(request.headers['if-none-match']).flatten.join(',')
      if !inm.empty? && (inm == '*' || inm.include?(etag))
        return Async::HTTP::Protocol::Response[304, { 'etag' => etag }, []]
      end

      entry = @cache[name]
      if entry.nil? || entry[:mtime] != mtime
        @cache[name] = { body: File.read(path), mtime: mtime }
      end

      body = Protocol::HTTP::Body::Buffered.wrap(@cache[name][:body])
      Async::HTTP::Protocol::Response[200,
        { 'content-type' => ct, 'etag' => etag, 'cache-control' => 'no-cache' },
        body]
    rescue Errno::ENOENT
      Dylan::Response.error(404, "Asset '#{name}' not found")
    end
  end
end
