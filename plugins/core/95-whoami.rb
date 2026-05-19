# frozen_string_literal: true

# Whoami Plugin — Gibt den Agent-Namen anhand der Caller-IP zurück.
# Wird von Milan-Agents beim Start genutzt, um sich zu identifizieren.
#
# Beispiel:
#   Milan (192.168.1.118) → GET http://dy.lan/whoami → "mini (192.168.1.118)"
#
# Nutzt Dylan::Milan.agents (cached + hot-reloaded in lib/milan.rb) —
# kein eigenes YAML-Loading mehr nötig.

WHOAMI_DOMAINS = ['dy.lan']

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

    agent_name = Dylan::Milan.agents.find do |_name, url|
      url.to_s =~ %r{//([^:/]+)} && $1 == caller_ip
    end&.first

    if agent_name
      Dylan::Response.text("#{agent_name} (#{caller_ip})")
    else
      Dylan::Response.error(404, "Unknown caller: #{caller_ip}")
    end
  end
end
