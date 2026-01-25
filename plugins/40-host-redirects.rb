# frozen_string_literal: true

require 'yaml'
require 'async/http/client'
require 'async/http/endpoint'

# Host-based Redirects Plugin
# Reverse Proxy functionality based on hostname
#
# Supports two modes:
# - redirect: HTTP 302 redirect (default, URL changes in browser)
# - proxy: Transparent reverse proxy (URL stays the same)
#
# Example YAML:
#   - pattern: 'syncthing\.lan'
#     target: 'http://192.168.1.118:8384'
#     type: redirect  # or: proxy

class HostRedirectsPlugin < Dylan::Plugin
  # No class-level pattern! We check dynamically against YAML
  pattern(/.^/)  # Matches nothing (we override match?)

  CONFIG_PATH = File.join(__dir__, '..', 'config', 'host-redirects.yaml')

  def initialize
    super
    @config_mtime = nil
    @redirects = load_redirects
    @clients = {}  # Client pool for proxy mode
    @last_reload_check = Time.now
    puts "    Loaded #{@redirects.count} host-based rule(s) from YAML"
  end

  # Override match? for hostname patterns
  def match?(host, path)
    # Quick check: any redirects configured?
    return false if @redirects.empty?

    # Only check for config changes every 5 seconds (not every request)
    # This prevents filesystem overhead on every request
    if Time.now - @last_reload_check > 5
      reload_if_changed
      @last_reload_check = Time.now
    end

    @redirects.any? { |r| host.match?(r[:pattern]) }
  end

  def call(host, path, request)
    rule = @redirects.find { |r| host.match(r[:pattern]) }
    return nil unless rule

    # Build target URL (base + path)
    # Path already contains query string from server.rb
    target_base = rule[:target].chomp('/')
    full_url = "#{target_base}#{path}"

    # Choose mode: proxy or redirect
    if rule[:type] == 'proxy'
      handle_proxy(target_base, path, request)
    else
      Dylan::Response.redirect(full_url)
    end
  end

  private

  # Proxy mode: Forward request to backend transparently
  def handle_proxy(target_base, path, request)
    # Parse target endpoint
    endpoint = Async::HTTP::Endpoint.parse(target_base)

    # Reuse client for performance (connection pooling)
    client = @clients[target_base] ||= Async::HTTP::Client.new(endpoint)

    # Build new request for backend
    # We need to create a new Request object with the path
    backend_request = Async::HTTP::Protocol::Request.new(
      endpoint.scheme,
      endpoint.authority,
      request.method,
      path,
      nil,  # version
      request.headers,
      request.body
    )

    # Forward request to backend
    backend_response = client.call(backend_request)

    # Return the response directly (already in correct format)
    backend_response
  rescue => e
    puts "❌ Proxy Error (#{target_base}#{path}): #{e.message}"
    puts "   #{e.backtrace&.first}"
    Dylan::Response.error(502, "Bad Gateway: #{e.message}")
  end

  def reload_if_changed
    return unless File.exist?(CONFIG_PATH)

    current_mtime = File.mtime(CONFIG_PATH)

    if @config_mtime.nil? || current_mtime > @config_mtime
      @config_mtime = current_mtime
      @redirects = load_redirects

      # Close old clients on config reload
      @clients.each_value(&:close)
      @clients.clear

      puts "🔄 Reloaded host-redirects.yaml (#{@redirects.count} rules)"
    end
  end

  def load_redirects
    return [] unless File.exist?(CONFIG_PATH)

    data = YAML.load_file(CONFIG_PATH)
    data['redirects'].map do |r|
      {
        pattern: Regexp.new(r['pattern']),
        target: r['target'],
        type: r['type'] || 'redirect',  # default: redirect
        description: r['description']
      }
    end
  rescue => e
    puts "WARNING: Could not load host-redirects.yaml: #{e.message}"
    []
  end
end
