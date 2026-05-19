# frozen_string_literal: true

# Dylan Plugin: Milan Connect
# Forwards requests to Milan agents configured in config/milan.yaml.
# Die HTTP-Logik und das Agent-Registry liegen in lib/milan.rb.
#
# Examples:
#   GET /mini/hello/world  ->  Mac Mini:  GET /hello/world
#   GET /book/hello/world  ->  MacBook:   GET /hello/world

MILAN_CONNECT_DOMAINS = ['mi.lan', 'dy.lan']

class MilanConnectPlugin < Dylan::Plugin
  pattern(%r{^/\w+/})
  timeout(5)  # Higher timeout for remote calls

  def match?(host, path)
    return false unless MILAN_CONNECT_DOMAINS.any? { |d| host.include?(d) }

    agent_name = path.split('/')[1]
    return false unless agent_name && Dylan::Milan.agent_url(agent_name)

    super
  end

  def call(host, path, request)
    return nil unless Dylan::Milan.enabled?

    parts = path.split('/', 3)  # ["", "mini", "hello/world"]
    agent_name     = parts[1]
    forwarded_path = parts[2] ? "/#{parts[2]}" : '/'

    Dylan::Milan.rescued(agent_name) do
      response = Dylan::Milan.get(agent_name, forwarded_path)
      Dylan::Response.text(response.body.strip)
    end
  end
end
