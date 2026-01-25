# frozen_string_literal: true

# Pattern Redirect Plugins
# Each plugin combines pattern matching + custom logic + domain filtering
#
# Domain Configuration (applies to all plugins in this file):
PATTERN_REDIRECT_DOMAINS = ['dy.lan']  # Only respond to these domains, empty for all

# Apple Shortcuts Integration: /n/TERM → shortcuts://run-shortcut?name=hook_notes&input=TERM
class NotesRedirectPlugin < Dylan::Plugin
  pattern(%r{^/n/(.+)$})

  def match?(host, path)
    return false unless PATTERN_REDIRECT_DOMAINS.empty? || PATTERN_REDIRECT_DOMAINS.include?(host)
    super(host, path)
  end

  def call(host, path, request)
    match = path.match(%r{^/n/(.+)$})
    search_term = match[1]

    Dylan::Response.redirect("shortcuts://run-shortcut?name=hook_notes&input=#{search_term}")
  end
end

# DEVONthink UUID Search: /XXXXXXXX → x-devonthink://search?query=XXXXXXXX
class DevonThinkPlugin < Dylan::Plugin
  pattern(%r{^/([a-zA-Z0-9]{8})$})

  def match?(host, path)
    return false unless PATTERN_REDIRECT_DOMAINS.empty? || PATTERN_REDIRECT_DOMAINS.include?(host)
    super(host, path)
  end

  def call(host, path, request)
    match = path.match(%r{^/([a-zA-Z0-9]{8})$})
    code = match[1]

    Dylan::Response.redirect("x-devonthink://search?query=#{code}")
  end
end
