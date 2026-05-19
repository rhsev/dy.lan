# frozen_string_literal: true

# Monitor Plugin — liefert die vom Bash-Skript erzeugte `monitor.html` an
# `/monitor` bzw. `/monitor.html`. Daten-Generierung läuft unabhängig (Cron),
# das Plugin ist reine Display-Schicht.
#
# Nutzt `Dylan::StaticAssets` für ETag-basiertes Browser-Caching und einen
# Server-Memory-Cache (kein File-Read pro Request).

class MonitorPlugin < Dylan::Plugin
  pattern(%r{^/(monitor|monitor\.html)$})

  def initialize
    super
    @assets = Dylan::StaticAssets.new(
      dir:   '/app/data',
      types: { 'monitor.html' => 'text/html; charset=UTF-8' }
    )
  end

  # Egal ob `/monitor` oder `/monitor.html` aufgerufen wird — beide liefern
  # dieselbe Datei. StaticAssets übernimmt 404 wenn die HTML noch nicht
  # vom Cron erzeugt wurde.
  def call(host, path, request)
    @assets.serve('monitor.html', request)
  end
end
