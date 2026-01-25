# frozen_string_literal: true

require 'yaml'

# Simple Redirects Plugin
# Loads redirects from YAML file - no Ruby code needed!
#
# Users can simply edit config/redirects.yaml

class SimpleRedirectsPlugin < Dylan::Plugin
  # No class-level pattern! We check dynamically against YAML
  pattern(/.^/)  # Matches nothing (we override match?)

  CONFIG_PATH = File.join(__dir__, '..', 'config', 'redirects.yaml')

  def initialize
    super
    @config_mtime = nil
    @redirects, @domains = load_redirects
    domain_info = @domains.empty? ? " (all domains)" : " (domains: #{@domains.join(', ')})"
    puts "    Loaded #{@redirects.count} simple redirect(s) from YAML#{domain_info}"
  end

  # Override match? for dynamic patterns
  def match?(host, path)
    # Check domain filter first (fast!)
    return false unless @domains.empty? || @domains.include?(host)

    # Only reload if domain matches
    reload_if_changed

    @redirects.any? { |r| path.match?(r[:pattern]) }
  end

  def call(host, path, request)
    @redirects.each do |redirect|
      if match = path.match(redirect[:pattern])
        # Replace ${1}, ${2}, etc. with capture groups
        target = redirect[:target].dup
        match.captures.each_with_index do |capture, index|
          target.gsub!("${#{index + 1}}", capture.to_s)
        end

        return Dylan::Response.redirect(target)
      end
    end

    nil  # No match
  end

  private

  def reload_if_changed
    return unless File.exist?(CONFIG_PATH)

    current_mtime = File.mtime(CONFIG_PATH)

    if @config_mtime.nil? || current_mtime > @config_mtime
      @config_mtime = current_mtime
      @redirects, @domains = load_redirects
      puts "🔄 Reloaded redirects.yaml (#{@redirects.count} redirects)" if @config_mtime
    end
  end

  def load_redirects
    return [[], []] unless File.exist?(CONFIG_PATH)

    data = YAML.load_file(CONFIG_PATH)

    domains = data['domains'] || []
    redirects = data['redirects'].map do |r|
      {
        pattern: Regexp.new(r['pattern']),
        target: r['target'],
        description: r['description']
      }
    end

    [redirects, domains]
  rescue => e
    puts "WARNING: Could not load redirects.yaml: #{e.message}"
    [[], []]
  end
end
