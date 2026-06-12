# frozen_string_literal: true

# Host-based Redirects Plugin — Reverse Proxy nach Hostname.
# Modi:
#   redirect: HTTP 302 (URL ändert sich im Browser, Default)
#   proxy:    Transparenter Reverse Proxy (URL bleibt)
#
# Beispiel-YAML (config/host-redirects.yaml):
#   redirects:
#     - pattern: 'syncthing\.lan'
#       target:  'http://192.168.1.118:8384'
#       type:    proxy   # default: redirect

class HostRedirectsPlugin < Dylan::Plugin
  pattern(/.^/)  # match? wird überschrieben — Pattern matcht nichts
  timeout(10)    # Proxy-Mode wartet auf Backends — 0.5s-Default wäre zu knapp
  config_file 'host-redirects.yaml'

  def initialize
    super
    @redirects = []
    @pool      = Dylan::HttpPool.new   # Proxy-Connection-Pool pro Target-URL
    config       # Initial-Load triggert on_config_reload
    puts "    Loaded #{@redirects.count} host-based rule(s) from YAML"
  end

  def match?(host, path)
    config       # Hot-Reload zuerst — sonst bleibt eine leere Config für immer leer
    return false if @redirects.empty?
    @redirects.any? { |r| host.match?(r[:pattern]) }
  end

  def call(host, path, request)
    rule = @redirects.find { |r| host.match(r[:pattern]) }
    return nil unless rule

    target_base = rule[:target].chomp('/')
    if rule[:type] == 'proxy'
      handle_proxy(target_base, path, request)
    else
      Dylan::Response.redirect("#{target_base}#{path}")
    end
  end

  protected

  def on_config_reload(data)
    @redirects = (data['redirects'] || []).map do |r|
      {
        pattern:     Regexp.new(r['pattern']),
        target:      r['target'],
        type:        r['type'] || 'redirect',
        description: r['description']
      }
    end
    # Cache der Proxy-Clients invalidieren — Targets könnten sich geändert haben
    @pool.clear!
    puts "🔄 Reloaded host-redirects.yaml (#{@redirects.count} rules)" if @config_mtime
  rescue => e
    puts "WARNING: Could not parse host-redirects.yaml: #{e.message}"
    @redirects = []
  end

  private

  def handle_proxy(target_base, path, request)
    client = @pool.for(target_base)
    # Endpoint nur für scheme/authority lokal parsen — Async::HTTP::Endpoint.parse
    # ist günstig (kein DNS, nur URI-Split) und vermeidet API-Abhängigkeit
    # auf interne Client-Attribute.
    endpoint = Async::HTTP::Endpoint.parse(target_base)

    backend_request = Async::HTTP::Protocol::Request.new(
      endpoint.scheme, endpoint.authority,
      request.method, path,
      nil, request.headers, request.body
    )

    client.call(backend_request)
  rescue => e
    puts "❌ Proxy Error (#{target_base}#{path}): #{e.message}"
    puts "   #{e.backtrace&.first}"
    Dylan::Response.error(502, "Bad Gateway: #{e.message}")
  end
end
