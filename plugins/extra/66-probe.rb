# frozen_string_literal: true

# Probe Plugin — dylan fragt die Maschinen selbst und interpretiert auch das
# Ausbleiben einer Antwort als Zustand.
#
# Gegenstück zur Widget-Inbox: dort bringen die Maschinen ihre Meldungen
# (Push, Anzeige stirbt mit milan-mini), hier holt dylan sie ab — jeder
# Milan-Agent aus config/milan.yaml wird auf /ops-book befragt
# (mi.lan/scripts/custom/ops-book.rb: erste Zeile "book ok" ist der Vertrag,
# danach Fakten). Der Poll ist damit der Totmannschalter über die
# Maschinengrenze hinweg: Mini und Book werden von der NAS aus beobachtet,
# die NAS vom Mini (check-ops). Landkarte: OPS.md im rhsev-Dach.
#
# Kein eigener Takt — gemessen wird beim Betrachten. Ein schlafendes Book
# ist "abwesend", kein Alarm; rot ist nur "antwortet, aber kaputt".
#
# Format wie 65-monitor: Markdown als text/plain — liest sich im Terminal
# natürlich, sitzt monospace in Stage's Output-Box, bleibt später renderbar.

require 'time'

class ProbePlugin < Dylan::Plugin
  pattern(%r{^/probe$})

  # Budget für alle Agents zusammen; pro Agent deutlich weniger, denn ein
  # schlafender Mac lehnt nicht ab, er droppt still — ohne eigenes Timeout
  # fräße ein Abwesender das ganze Plugin-Budget.
  timeout(6.0)
  AGENT_TIMEOUT = 2

  def call(host, path, request)
    lines = ["# probe · #{Time.now.strftime('%d.%m. %H:%M:%S')}", '']
    Dylan::Milan.agents.each_key { |name| lines << probe_line(name) }
    lines << nas_line
    lines << ''
    lines << '✅ meldet sich · 💤 abwesend/schläft (normal) · 🟥 antwortet, aber kaputt'
    Dylan::Response.text(lines.join("\n") + "\n")
  end

  private

  # ── NAS-Selbstauskunft ─────────────────────────────────────────────────────
  # Die NAS hat kein milan — ihre Auskunftsfläche ist dylan selbst. Gelesen
  # werden die Spuren der Wartungsjobs (read-only-Mount /nas-scripts aus der
  # compose); check-ops auf dem Mini liest dieselben Logs über SMB — zwei
  # Blickwinkel auf denselben Nachweis, mit Absicht.

  NAS_LOGS        = '/nas-scripts'
  NAS_FRESH_HOURS = 26  # Tagesjobs + Luft, wie in check-ops
  STAMP           = /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/.source

  def nas_line
    unless File.directory?(NAS_LOGS)
      return "💤 nas — Log-Mount fehlt noch (#{NAS_LOGS}; kommt mit dem nächsten Stack-Ausrollen)"
    end

    facts = [
      nas_fact('stacks', 'update-stacks.log', /^\[#{STAMP}\] Update complete!/o),
      nas_fact('dovecot-cert', 'startup.log', /^\[#{STAMP}\] renew-dovecot-cert:/o),
    ]
    glyph = facts.any? { |ok, _| !ok } ? '🟥' : '✅'
    "#{glyph} nas — #{facts.map(&:last).join(' · ')}"
  end

  # Letzter Treffer vom Dateiende her; die Logs wachsen (update-stacks.log
  # steht bei ~700 KB). Rückgabe: [ok, text].
  def nas_fact(label, file, re)
    path = File.join(NAS_LOGS, file)
    return [false, "#{label}: #{file} fehlt"] unless File.file?(path)

    tail = File.open(path, 'rb') do |f|
      f.seek([f.size - 131_072, 0].max)
      f.read
    end.force_encoding('UTF-8').scrub
    line = tail.lines.reverse.find { |l| l =~ re }
    return [false, "#{label}: keine Zeile in #{file}"] unless line

    hours = ((Time.now - Time.strptime(line.match(re)[1], '%Y-%m-%d %H:%M:%S')) / 3600).round
    [hours <= NAS_FRESH_HOURS, "#{label} vor #{hours}h#{" (> #{NAS_FRESH_HOURS}h!)" if hours > NAS_FRESH_HOURS}"]
  end

  def probe_line(name)
    body = Async::Task.current.with_timeout(AGENT_TIMEOUT) do
      Dylan::Milan.get(name, '/ops-book').body
    end
    facts = body.to_s.lines.map(&:strip).reject(&:empty?)
    return "✅ #{name} — #{facts.drop(1).join(' · ')}" if facts.first == 'book ok'

    "🟥 #{name} — antwortet, aber /ops-book scheitert (#{facts.first.to_s[0, 60]})"
  rescue Async::TimeoutError, Dylan::Milan::UnreachableError
    "💤 #{name} — keine Antwort"
  rescue Dylan::Milan::UnknownAgentError => e
    "🟥 #{name} — #{e.message}"
  end
end
