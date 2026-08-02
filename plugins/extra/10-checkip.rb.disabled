# frozen_string_literal: true

# CheckIP Plugin - IPv4 and IPv6
# Emulates Synology CheckIP Service

class CheckIPPlugin < Dylan::Plugin
  pattern(/checkip.*\.synology\.com/)

  IPV4_ADDRESS = "203.0.113.1"
  IPV6_ADDRESS = "2001:db8::1"

  def call(host, path, request)
    # IPv6 Check
    if host.include?('checkipv6')
      body = "Current IP Address: #{IPV6_ADDRESS}"
    else
      # Default: IPv4
      body = "Current IP Address: #{IPV4_ADDRESS}"
    end

    Dylan::Response.text(body)
  end
end
