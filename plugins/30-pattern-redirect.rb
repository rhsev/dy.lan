# frozen_string_literal: true

PATTERN_REDIRECT_DOMAINS = ['dy.lan', 'p.lan']

class Dylan::Plugin
  # Gemeinsame Logik für alle Plugins in dieser Datei
  def domain_allowed?(host)
    PATTERN_REDIRECT_DOMAINS.empty? || PATTERN_REDIRECT_DOMAINS.include?(host)
  end
end

class NotesRedirectPlugin < Dylan::Plugin
  pattern(%r{^/n/(.+)$})

  def match?(host, path)
    domain_allowed?(host) && super
  end

  def call(host, path, request)
    # Nutzt das bereits definierte Pattern aus der Klasse
    search_term = path.match(self.class.pattern)[1]
    Dylan::Response.redirect("shortcuts://run-shortcut?name=hook_notes&input=#{search_term}")
  end
end

class DevonThinkPlugin < Dylan::Plugin
  pattern(%r{^/([a-zA-Z0-9]{8})$})

  def match?(host, path)
    domain_allowed?(host) && super
  end

  def call(host, path, request)
    code = path.match(self.class.pattern)[1]
    Dylan::Response.redirect("x-devonthink://search?query=#{code}")
  end
end