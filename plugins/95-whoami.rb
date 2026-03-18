# frozen_string_literal: true

# Dylan Plugin: Whoami
# Returns the agent name based on caller's IP address
#
# Used by Milan agents to verify their identity at startup.
# Looks up the IP in config/milan.yaml and returns the agent name.
#
# Example:
#   Milan (192.168.1.118) calls: GET http://dy.lan/whoami
#   Response: "mini"

require 'yaml'

WHOAMI_DOMAINS = ['dy.lan']
WHOAMI_CONFIG_PATH = File.join(__dir__, '..', 'config', 'milan.yaml')

class WhoamiPlugin < Dylan::Plugin
  pattern(%r{^/whoami$})
  timeout(1)

  def match?(host, path)
    return false unless WHOAMI_DOMAINS.any? { |d| host.include?(d) }
    super
  end

  def call(host, path, request)
    caller_ip = request.remote_address&.ip_address rescue nil
    return Dylan::Response.error(400, 'Cannot determine caller IP') unless caller_ip

    # Load milan config
    config = load_milan_config
    return Dylan::Response.error(500, 'Milan config not found') unless config

    agents = config['agents'] || {}

    # Find agent by IP
    agent_name = find_agent_by_ip(agents, caller_ip)

    if agent_name
      Dylan::Response.text("#{agent_name} (#{caller_ip})")
    else
      Dylan::Response.error(404, "Unknown caller: #{caller_ip}")
    end
  end

  private

  def load_milan_config
    return nil unless File.exist?(WHOAMI_CONFIG_PATH)
    YAML.load_file(WHOAMI_CONFIG_PATH)['milan']
  rescue => e
    puts "[Whoami] Config error: #{e.message}"
    nil
  end

  # Find agent name by IP (extracts IP from URL like "http://192.168.1.118:8080")
  def find_agent_by_ip(agents, caller_ip)
    agents.each do |name, url|
      # Extract IP from URL
      if url =~ %r{//([^:/]+)}
        agent_ip = $1
        return name if agent_ip == caller_ip
      end
    end
    nil
  end
end
