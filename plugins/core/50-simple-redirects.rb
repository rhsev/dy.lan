# frozen_string_literal: true

# Simple Redirects Plugin
# Lädt Redirects aus config/redirects.yaml — kein Ruby-Code nötig.
# Hot-Reload via Dylan::Plugin#config (mtime-getriggert).

class SimpleRedirectsPlugin < Dylan::Plugin
  pattern(/.^/)
  config_file 'redirects.yaml'

  def initialize
    super
    @redirects = []
    @domains   = []
    config
    domain_info = @domains.empty? ? " (all domains)" : " (domains: #{@domains.join(', ')})"
    puts "    Loaded #{@redirects.count} simple redirect(s) from YAML#{domain_info}"
  end

  def match?(host, path)
    return false unless @domains.empty? || @domains.include?(host)
    config       # ggf. Hot-Reload
    @redirects.any? { |r| path.match?(r[:pattern]) }
  end

  def call(host, path, request)
    @redirects.each do |redirect|
      if match = path.match(redirect[:pattern])
        target = redirect[:target].dup
        match.captures.each_with_index { |capture, i| target.gsub!("${#{i + 1}}", capture.to_s) }
        return Dylan::Response.redirect(target)
      end
    end
    nil
  end

  protected

  def on_config_reload(data)
    @domains   = data['domains'] || []
    @redirects = (data['redirects'] || []).map do |r|
      {
        pattern:     Regexp.new(r['pattern']),
        target:      r['target'],
        description: r['description']
      }
    end
    puts "🔄 Reloaded redirects.yaml (#{@redirects.count} redirects)" if @config_mtime
  rescue => e
    puts "WARNING: Could not parse redirects.yaml: #{e.message}"
    @redirects = []
    @domains   = []
  end
end
