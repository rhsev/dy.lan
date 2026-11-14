# frozen_string_literal: true

# Dylan Plugin: Milan Connect
# Forwards requests to Milan agents configured in config/milan.yaml.
# Die HTTP-Logik und das Agent-Registry liegen in lib/milan.rb.
#
# Examples:
#   GET  /mini/hello/world      ->  Mac Mini:  GET  /hello/world
#   GET  /book/hello/world      ->  MacBook:   GET  /hello/world
#   POST /mini/receive          ->  Mac Mini:  POST /receive   (body -> the script's stdin)
#   GET  /mini/stream/backup    ->  Mac Mini:  GET  /stream/backup, passed on line by line
#
# Everything milan answers at <agent>:8080/<path> it answers here at
# /<agent>/<path>: the same methods, the same status, the same body. A stream
# is not collected first, and it is not bound by this plugin's timeout.

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

    method = request.method.to_s.upcase
    unless Dylan::Milan::METHODS.include?(method)
      return Dylan::Response.error(405, "Method #{method} is not forwarded (#{Dylan::Milan::METHODS.join(', ')})")
    end

    # milan's status travels with the body: a failed script answers 422 there,
    # and a 200 here would paint the failure green in the pad.
    Dylan::Milan.rescued(agent_name) do
      options = { method: method, body: payload(request, method), headers: passed_headers(request) }

      # /stream/<script> runs as long as the script does. Collecting it would
      # show nothing until the end and fail after this plugin's timeout.
      next Dylan::Milan.pass_stream(agent_name, forwarded_path, **options) if forwarded_path.start_with?('/stream/')

      response = Dylan::Milan.request(agent_name, forwarded_path, **options)
      ct = Array(response.headers['content-type']).first.to_s

      if ct.start_with?('text/html')
        # Skripte dürfen ganze Seiten liefern (z.B. das markbinder-Album).
        # Absolute Milan-Routen im Markup brauchen durch den Proxy das
        # Agent-Präfix, sonst laufen die Asset-Requests an Dylan ins Leere.
        html = Dylan::Milan.prefix_notes_links(response.body, "/#{agent_name}")
        Dylan::Response.html(html, status: response.status)
      elsif ct.empty? || ct.start_with?('text/')
        Dylan::Response.text(response.body.strip, status: response.status)
      else
        # Binär (Bilder & Co. von der Notes-Route) unverändert durchreichen.
        body = Protocol::HTTP::Body::Buffered.wrap(response.body)
        Async::HTTP::Protocol::Response[response.status, { 'content-type' => ct }, body]
      end
    end
  end

  private

  # The request body, for the methods that carry one. milan hands it to the
  # script on stdin.
  def payload(request, method)
    return nil unless %w[POST PUT].include?(method)

    request.read.to_s
  end

  # What milan needs to see of the caller's headers: the body's type, and the
  # signature a script with a secret checks the body against.
  PASSED_HEADERS = %w[content-type x-hub-signature-256].freeze

  def passed_headers(request)
    PASSED_HEADERS.filter_map do |name|
      value = Array(request.headers[name]).first
      [name, value] if value
    end
  end
end
