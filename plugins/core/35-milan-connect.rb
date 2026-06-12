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
      ct = response.headers['content-type'].to_s

      if ct.start_with?('text/html')
        # Skripte dürfen ganze Seiten liefern (z.B. das markbinder-Album).
        # Absolute Milan-Routen im Markup brauchen durch den Proxy das
        # Agent-Präfix, sonst laufen die Asset-Requests an Dylan ins Leere.
        html = response.body.gsub(%r{\b(src|href)="/(notes/[^"]*)"}) do
          "#{Regexp.last_match(1)}=\"/#{agent_name}/#{Regexp.last_match(2)}\""
        end
        Dylan::Response.html(html)
      elsif ct.empty? || ct.start_with?('text/')
        Dylan::Response.text(response.body.strip)
      else
        # Binär (Bilder & Co. von der Notes-Route) unverändert durchreichen.
        body = Protocol::HTTP::Body::Buffered.wrap(response.body)
        Async::HTTP::Protocol::Response[200, { 'content-type' => ct }, body]
      end
    end
  end
end
