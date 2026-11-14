# frozen_string_literal: true

require 'yaml'

module Dylan
  # Base class for all Dylan plugins
  # Plugins inherit from this class and define patterns + handlers
  class Plugin
    @registered_plugins = []

    class << self
      attr_reader :registered_plugins

      # Class-level pattern
      def pattern(regex = nil)
        @pattern = regex if regex
        @pattern
      end

      # Class-level timeout (in seconds)
      # Default: 0.5s (500ms) - can be overridden per plugin.
      # A class without its own value takes its parent's: class-level instance
      # variables are not inherited, so `timeout(5.0)` on an abstract base used
      # to leave every concrete subclass at the 0.5s default.
      def timeout(seconds = nil)
        @timeout = seconds if seconds
        @timeout || (equal?(Dylan::Plugin) ? 0.5 : superclass.timeout)
      end

      # Optionales YAML im config/-Verzeichnis. Aktiviert Hot-Reload via #config.
      #   config_file 'host-redirects.yaml'
      def config_file(filename = nil)
        @config_file = filename if filename
        @config_file
      end

      # Optional: nur diese Top-Level-Section aus dem YAML zurückgeben.
      #   config_section 'pad'  # → YAML['pad']
      def config_section(key = nil)
        @config_section = key if key
        @config_section
      end

      # Throttle für mtime-Checks (Sekunden). 0 = bei jedem Zugriff stat'en.
      # Default 5s — Edits werden in wenigen Sekunden sichtbar, FS-Calls bleiben minimal.
      def config_check_interval(seconds = nil)
        @config_check_interval = seconds if seconds
        @config_check_interval || (equal?(Dylan::Plugin) ? 5 : superclass.config_check_interval)
      end

      # Markiert diese Klasse als abstrakte Basis — der Router lädt sie nicht
      # als routbares Plugin. Subclasses werden weiterhin automatisch registriert.
      # Nützlich für Plugin-Familien (z.B. Multi-Instance-Setups: gemeinsame Logik
      # in einer Basis, pro Instance eine schlanke Subclass mit eigenem Pattern/Config).
      def abstract
        Dylan::Plugin.registered_plugins.delete(self)
      end

      # Auto-registration when inherited.
      # Bei Mehrfach-Vererbung (z.B. PadPlugin < PadBase < Plugin) ist `self` die
      # *direkte* Eltern-Klasse, deren `@registered_plugins` nil ist — wir müssen
      # explizit auf Dylan::Plugin's Registry zugreifen.
      def inherited(subclass)
        super
        Dylan::Plugin.registered_plugins << subclass
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

    # ─── Routing API (to be overridden) ─────────────────────────────────────

    def pattern  = self.class.pattern
    def timeout  = self.class.timeout

    def call(host, path, request)
      raise NotImplementedError, "Plugin #{self.class} must implement #call"
    end

    def match?(host, path)
      pattern.match(host) || pattern.match(path)
    end

    # Query parameters of a request as a Hash. Dylan's request.path carries the
    # query string. Values are returned as sent, not URL-decoded.
    def query_params(request)
      query_string = request.path.split('?', 2)[1] || ''
      query_string.split('&').each_with_object({}) do |pair, hash|
        key, value = pair.split('=', 2)
        hash[key] = value if key
      end
    end

    # ─── Config-Hot-Reload ──────────────────────────────────────────────────

    # Letzter geladener mtime — Subclasses können das nutzen um abgeleitete
    # Caches selbst zu invalidieren, ohne über on_config_reload zu gehen.
    attr_reader :config_mtime

    # Liefert die geparsten Config-Daten. Prüft mtime maximal alle
    # config_check_interval Sekunden. Bei echter Änderung wird on_config_reload aufgerufen.
    def config
      maybe_reload_config
      @config_data
    end

    protected

    # Hook für Subclasses: wird einmal beim Erst-Load und danach bei jeder
    # tatsächlichen mtime-Änderung aufgerufen. Default: no-op.
    def on_config_reload(data)
    end

    private

    def maybe_reload_config
      interval = self.class.config_check_interval
      now = Time.now
      return if interval > 0 && @config_last_stat && (now - @config_last_stat) < interval
      @config_last_stat = now

      path = config_path
      return unless path && File.exist?(path)

      mtime = File.mtime(path)
      return if mtime == @config_mtime

      raw = YAML.load_file(path) || {}
      section = self.class.config_section
      @config_data = section ? (raw[section] || {}) : raw
      @config_mtime = mtime
      on_config_reload(@config_data)
    rescue => e
      warn "[#{self.class.name}] Config error: #{e.message}"
    end

    def config_path
      filename = self.class.config_file
      filename && File.join(__dir__, '..', 'config', filename)
    end
  end
end
