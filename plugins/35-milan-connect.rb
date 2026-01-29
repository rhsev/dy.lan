# frozen_string_literal: true

# Dylan Plugin: Milan Connect
# Forwards requests to multiple Milan agents
#
# Config in config/milan.yaml:
#   milan:
#     enabled: true
#     agents:
#       mini: "http://192.168.1.118:8080"   # Mac Mini
#       book: "http://192.168.1.188:8080"   # MacBook
#
# Examples:
#   GET /mini/hello/world  ->  Mac Mini: GET /hello/world
#   GET /book/hello/world  ->  MacBook:  GET /hello/world

require 'yaml'

# Only respond to these domains
MILAN_CONNECT_DOMAINS = ['mi.lan']

class MilanConnectPlugin < Dylan::Plugin
  # Match any path starting with /<word>/
  pattern(%r{^/\w+/})
  timeout(5)  # Higher timeout for remote calls

  CONFIG_PATH = File.join(__dir__, '..', 'config', 'milan.yaml')
  CONFIG_CHECK_INTERVAL = 10  # seconds

  def initialize
    @config = nil
    @config_loaded_at = nil
    @http_clients = {}
    load_config
  end

  def match?(host, path)
    # Only match configured domains
    return false unless MILAN_CONNECT_DOMAINS.any? { |d| host.include?(d) }

    # Only match if first path segment is a configured agent
    load_config
    agent_name = path.split('/')[1]
    return false unless agent_name && @config&.dig('agents', agent_name)

    super
  end

  def call(host, path, request)
    return nil unless @config && @config['enabled'] != false

    # Extract agent name and forwarded path
    # /mini/hello/world -> agent: "mini", path: "/hello/world"
    parts = path.split('/', 3)  # ["", "mini", "hello/world"]
    agent_name = parts[1]
    forwarded_path = parts[2] ? "/#{parts[2]}" : '/'

    forward_to_milan(agent_name, forwarded_path)
  end

  private

  # Load config (with hot-reload)
  def load_config
    return @config if @config && @config_loaded_at &&
                      (Time.now - @config_loaded_at) < CONFIG_CHECK_INTERVAL

    return nil unless File.exist?(CONFIG_PATH)

    @config = YAML.load_file(CONFIG_PATH)['milan'] || {}
    @config['agents'] ||= {}
    @config_loaded_at = Time.now

    # Reset HTTP clients on config change
    @http_clients = {}

    @config
  rescue => e
    puts "[MilanConnect] Config error: #{e.message}"
    @config = nil
  end

  # HTTP client per agent (reusable for connection pooling)
  def http_client(agent_name)
    @http_clients[agent_name] ||= begin
      url = @config.dig('agents', agent_name)
      return nil unless url
      endpoint = Async::HTTP::Endpoint.parse(url)
      Async::HTTP::Client.new(endpoint)
    end
  end

  # Forward request to Milan agent
  def forward_to_milan(agent_name, path)
    load_config  # Hot-reload check

    client = http_client(agent_name)
    unless client
      return Dylan::Response.error(404, "Unknown Milan agent: #{agent_name}")
    end

    begin
      response = client.get(path)
      body = response.read || ''

      Dylan::Response.text(body.strip)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      Dylan::Response.error(503, "Milan '#{agent_name}' unreachable")
    rescue => e
      Dylan::Response.error(502, "Milan error: #{e.message}")
    end
  end
end
