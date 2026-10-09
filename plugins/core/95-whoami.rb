# frozen_string_literal: true

require 'uri'

# Whoami Plugin — milan agents call this on start to confirm who they are.
#
# With ?name= the agent states its name and Dylan checks the claim against the
# address the request came from:
#   milan (192.168.1.118) → GET http://dy.lan/whoami?name=mini → 200 "mini (192.168.1.118)"
#   book, bridged over the mini and NATed to .118 → GET http://dy.lan/whoami?name=book
#     → 409 "book is registered at 192.168.1.187 but called from 192.168.1.118 (registered as mini)"
#
# A claim may also come from an address listed under whoami_also_from in
# milan.yaml — for the MacBook on the cable, which reaches Dylan as .118:
#   whoami_also_from:
#     book: ["192.168.1.118"]
# Such an OK says who the caller is, not that Dylan can reach it: actions
# still go to the address under agents.
#
# Without a name the agent is looked up by caller address alone, as before —
# kept for milan binaries that predate ?name=. Behind NAT that answer names
# the router's agent instead of the caller, which is why milan now sends one.
#
# Uses Dylan::Milan.agents (cached + hot-reloaded in lib/milan.rb).

WHOAMI_DOMAINS = ['dy.lan']

class WhoamiPlugin < Dylan::Plugin
  # The router matches against the full request path, query included.
  pattern(%r{^/whoami(\?|$)})
  timeout(1)
  config_file 'milan.yaml'
  config_section 'milan'

  def match?(host, path)
    return false unless WHOAMI_DOMAINS.any? { |d| host.include?(d) }
    super
  end

  def call(host, path, request)
    caller_ip = request.remote_address&.ip_address rescue nil
    return Dylan::Response.error(400, 'Cannot determine caller IP') unless caller_ip

    query = path.split('?', 2)[1].to_s
    name = begin
      URI.decode_www_form(query).assoc('name')&.last
    rescue ArgumentError
      return Dylan::Response.error(400, 'Malformed query string')
    end
    return identify_by_address(caller_ip) unless name

    url = Dylan::Milan.agents[name]
    return Dylan::Response.error(404, "Unknown agent: #{name}") unless url

    registered_ip = host_of(url)
    if registered_ip == caller_ip || also_from(name).include?(caller_ip)
      return Dylan::Response.text("#{name} (#{caller_ip})")
    end

    message = +"#{name} is registered at #{registered_ip} but called from #{caller_ip}"
    other = agent_at(caller_ip)
    message << " (registered as #{other})" if other
    Dylan::Response.error(409, message)
  end

  private

  def identify_by_address(caller_ip)
    agent_name = agent_at(caller_ip)
    if agent_name
      Dylan::Response.text("#{agent_name} (#{caller_ip})")
    else
      Dylan::Response.error(404, "Unknown caller: #{caller_ip}")
    end
  end

  def also_from(name)
    Array((config || {}).dig('whoami_also_from', name)).map(&:to_s)
  end

  def agent_at(ip)
    Dylan::Milan.agents.find { |_name, url| host_of(url) == ip }&.first
  end

  def host_of(url)
    url.to_s[%r{//([^:/]+)}, 1]
  end
end
