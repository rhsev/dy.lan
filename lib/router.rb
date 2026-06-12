# frozen_string_literal: true

require 'set'
require 'yaml'

module Dylan
  # Router manages all plugins and routes requests
  # First-Match-Wins: Plugins in load order (alphabetical)
  class Router
    attr_reader :stats, :plugin_dir, :disabled_plugins, :runtime_config

    def initialize(plugin_dir = nil)
      @plugins = []
      @plugin_dir = plugin_dir
      @stats = {
        started_at: Time.now,
        total_requests: 0,
        requests_by_plugin: Hash.new(0),
        errors_by_plugin: Hash.new(0)
      }
      @disabled_plugins = Set.new  # Circuit breaker: Track disabled plugins
      @disabled_until   = {}       # plugin_name => Time (Auto-Re-Enable)
      @error_times      = Hash.new { |h, k| h[k] = [] }  # Fehler-Timestamps im Fenster
      @runtime_config = load_runtime_config
    end

    # Add plugin instance
    # @param plugin_class [Class] Plugin class (subclass of Dylan::Plugin)
    def add_plugin(plugin_class)
      instance = if ruby_box_enabled?
        build_plugin_with_box(plugin_class)
      else
        plugin_class.build
      end

      @plugins << instance
      timeout_info = instance.timeout == 0.5 ? "" : " [timeout: #{instance.timeout}s]"
      box_info = ruby_box_enabled? ? " [Ruby::Box]" : ""
      puts "  Registered: #{plugin_class.name} (pattern: #{instance.pattern.inspect})#{timeout_info}#{box_info}"
    end

    # Route request to matching plugin
    # @param host [String]
    # @param path [String]
    # @param request [Async::HTTP::Protocol::Request]
    # @return [Async::HTTP::Protocol::Response]
    def call(host, path, request)
      @stats[:total_requests] += 1

      # Ruby 4.0: Nutze 'it' Parameter für kompakteren Code
      @plugins.each do |plugin|
        plugin_name = plugin.class.name

        # Circuit breaker: Skip disabled plugins (Auto-Re-Enable nach Cooldown)
        if @disabled_plugins.include?(plugin_name)
          next if Time.now < @disabled_until.fetch(plugin_name, Time.now)
          @disabled_plugins.delete(plugin_name)
          @disabled_until.delete(plugin_name)
          @error_times[plugin_name].clear
          puts "✅ CIRCUIT BREAKER: #{plugin_name} re-enabled after cooldown"
        end

        begin
          # match? ist billig (Regex/Lookup) und läuft ohne Timeout-Wrapper;
          # nur der eigentliche call wird mit dem Plugin-Timeout geschützt.
          next unless plugin.match?(host, path)

          plugin_timeout = plugin.timeout
          response = Async::Task.current.with_timeout(plugin_timeout) do
            plugin.call(host, path, request)
          end

          if response
            @stats[:requests_by_plugin][plugin_name] += 1
            return response
          end
        rescue Async::TimeoutError
          handle_plugin_error(plugin_name, "TIMEOUT (>#{plugin_timeout}s)", path)
          next # Try next plugin
        rescue => e
          handle_plugin_error(plugin_name, e.message, path, e.backtrace&.first)
          next # Continue to next plugin despite error
        end
      end

      # 404 Fallback
      Response.not_found
    end

    # Number of registered routes
    def route_count
      @plugins.count
    end

    # List all plugins (for debugging)
    def plugins
      @plugins
    end

    # Server uptime in seconds
    def uptime
      Time.now - @stats[:started_at]
    end

    private

    # Load runtime configuration from config/runtime.yaml
    def load_runtime_config
      config_path = File.join(__dir__, '..', 'config', 'runtime.yaml')
      return default_runtime_config unless File.exist?(config_path)

      YAML.load_file(config_path) || default_runtime_config  # leere Datei → nil
    rescue => e
      puts "WARNING: Could not load runtime.yaml: #{e.message}"
      default_runtime_config
    end

    # Default runtime configuration
    def default_runtime_config
      {
        'ruby_box' => { 'enabled' => false },
        'zjit' => { 'enabled' => false }
      }
    end

    # Check if Ruby::Box is enabled
    def ruby_box_enabled?
      @runtime_config.dig('ruby_box', 'enabled') && defined?(Ruby::Box)
    end

    # Build plugin with Ruby::Box isolation (experimental)
    def build_plugin_with_box(plugin_class)
      box = Ruby::Box.new(name: "Box-#{plugin_class.name}")
      box.eval("#{plugin_class.name}.new")
    rescue => e
      puts "WARNING: Ruby::Box failed for #{plugin_class.name}: #{e.message}"
      puts "         Falling back to standard build"
      plugin_class.build
    end

    # Handle plugin errors with circuit breaker.
    # 5 Fehler innerhalb von ERROR_WINDOW Sekunden deaktivieren das Plugin
    # für DISABLE_COOLDOWN Sekunden (danach Auto-Re-Enable). Vereinzelte
    # Fehler über Wochen führen so nicht mehr zur Dauer-Abschaltung.
    ERROR_THRESHOLD  = 5
    ERROR_WINDOW     = 60    # Sekunden
    DISABLE_COOLDOWN = 300   # Sekunden

    def handle_plugin_error(plugin_name, error_msg, path, location = nil)
      @stats[:errors_by_plugin][plugin_name] += 1

      now = Time.now
      times = @error_times[plugin_name]
      times << now
      times.shift while times.first && (now - times.first) > ERROR_WINDOW

      if times.size >= ERROR_THRESHOLD && !@disabled_plugins.include?(plugin_name)
        @disabled_plugins << plugin_name
        @disabled_until[plugin_name] = now + DISABLE_COOLDOWN
        puts "🚨 CIRCUIT BREAKER: #{plugin_name} disabled for #{DISABLE_COOLDOWN}s " \
             "(#{times.size} errors in #{ERROR_WINDOW}s)"
      else
        puts "❌ ERROR in #{plugin_name}: #{error_msg} (path: #{path})"
        puts "   Location: #{location}" if location
        puts "   Error count: #{times.size}/#{ERROR_THRESHOLD} (#{ERROR_WINDOW}s window)"
      end
    end
  end
end
