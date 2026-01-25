# frozen_string_literal: true

module Dylan
  # Base class for all Dylan plugins
  # Plugins inherit from this class and define patterns + handlers
  class Plugin
    @registered_plugins = []

    class << self
      attr_reader :registered_plugins

      # Class-level pattern
      def pattern(regex = nil)
        if regex
          @pattern = regex
        end
        @pattern
      end

      # Class-level timeout (in seconds)
      # Default: 0.5s (500ms) - can be overridden per plugin
      def timeout(seconds = nil)
        if seconds
          @timeout = seconds
        end
        @timeout || 0.5  # Default 500ms
      end

      # Auto-registration when inherited
      def inherited(subclass)
        super
        @registered_plugins << subclass
      end

      # Clear all registered plugins (for hot-reload)
      def clear_registered!
        @registered_plugins.clear
      end

      # Factory method for new instance
      def build
        new
      end
    end

    # Instance methods (to be overridden in plugins)

    # Returns pattern (can be instance-specific)
    def pattern
      self.class.pattern
    end

    # Returns timeout in seconds (can be instance-specific)
    def timeout
      self.class.timeout
    end

    # Handler method (MUST be overridden by plugin)
    # @param host [String] Host header
    # @param path [String] Request path
    # @param request [Async::HTTP::Protocol::Request] Full request object
    # @return [Async::HTTP::Protocol::Response, nil] Response or nil
    def call(host, path, request)
      raise NotImplementedError, "Plugin #{self.class} must implement #call"
    end

    # Helper: Match request against pattern
    # @return [MatchData, nil]
    def match?(host, path)
      pattern.match(host) || pattern.match(path)
    end
  end
end
