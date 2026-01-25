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

        # Circuit breaker: Skip disabled plugins
        if @disabled_plugins.include?(plugin_name)
          next
        end

        begin
          # Timeout protection: Use plugin-specific timeout (default 500ms)
          plugin_timeout = plugin.timeout

          # Optimization: Only wrap in timeout if custom timeout is set
          # Default 0.5s timeout is handled by async-http server config
          response = if plugin_timeout != 0.5
            Async::Task.current.with_timeout(plugin_timeout) do
              if match = plugin.match?(host, path)
                plugin.call(host, path, request)
              end
            end
          else
            # Fast path: No timeout wrapper for default plugins
            if match = plugin.match?(host, path)
              plugin.call(host, path, request)
            end
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

      YAML.load_file(config_path)
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

    # Handle plugin errors with circuit breaker
    # After 5 errors, disable the plugin to prevent log spam
    def handle_plugin_error(plugin_name, error_msg, path, location = nil)
      @stats[:errors_by_plugin][plugin_name] += 1
      error_count = @stats[:errors_by_plugin][plugin_name]

      if error_count >= 5 && !@disabled_plugins.include?(plugin_name)
        @disabled_plugins << plugin_name
        puts "🚨 CIRCUIT BREAKER: #{plugin_name} disabled after #{error_count} errors"
      else
        puts "❌ ERROR in #{plugin_name}: #{error_msg} (path: #{path})"
        puts "   Location: #{location}" if location
        puts "   Error count: #{error_count}/5" if error_count < 5
      end
    end
  end
end
