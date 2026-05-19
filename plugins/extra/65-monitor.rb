# frozen_string_literal: true

# Monitor Plugin — liefert den vom Bash-Skript erzeugten Markdown-Status-Report
# an `/monitor`. Daten-Generierung läuft unabhängig (Cron), das Plugin ist reine
# Display-Schicht.
#
# Format: Markdown als `text/plain` — liest sich im Terminal natürlich (Emoji
# als Status-Indikator), in Stage's Output-Box monospace-formatiert, und kann
# bei Bedarf später durch einen Renderer geschickt werden.
#
# Nutzt `Dylan::StaticAssets` für ETag-basiertes Browser-Caching und einen
# Server-Memory-Cache (kein File-Read pro Request).

class MonitorPlugin < Dylan::Plugin
  pattern(%r{^/monitor$})

  def initialize
    super
    @assets = Dylan::StaticAssets.new(
      dir:   '/app/data',
      types: { 'monitor.md' => 'text/plain; charset=UTF-8' }
    )
  end

  # StaticAssets übernimmt 404 wenn die Markdown-Datei noch nicht vom Cron
  # erzeugt wurde.
  def call(host, path, request)
    @assets.serve('monitor.md', request)
  end
end
