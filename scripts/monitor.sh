#!/bin/bash
# Network Monitor — generates a Markdown report of ACTIVE devices on the LAN
# and writes it to /app/data/monitor.md. The Dylan plugin serves the file as
# text/plain; Stage (Output-Box) and direct /monitor visits see the same text.
#
# Seit 27.08.2026 zwei Sektionen: die WACHE (sind bestimmte Geräte an —
# der Ursprungszweck; VMs, auch als Board-Tiles) und der SWEEP (wer
# antwortet gerade im /24, mit PTR-Namen — die Nachschlage-Ansicht). Die
# alte Services-Sektion (milan-Ports) ist von /probe und den Stage-Badges
# abgedeckt; die LiveSync-Zeilen leben als Board-Tiles weiter — dieses
# Skript bleibt ihr WÄCHTER (unten).
#
# Cron schedule: config/crontab (alle 5 Minuten).
#
# Robustheit:
#   - Atomic write via temp file + mv: Reader sehen nie eine halb-geschriebene
#     Datei; während des Laufs bleibt die alte monitor.md verfügbar.
#   - TZ explizit setzen: Cronie erbt nicht zwingend die Container-ENV,
#     `date` gäbe sonst UTC aus.

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ="${TZ:-Europe/Berlin}"

OUTPUT="/app/data/monitor.md"
TMP_OUTPUT="${OUTPUT}.tmp"

SUBNET="192.168.1"
# Bekannt-lebende Referenz: meldet sie sich im Sweep nicht, ist ICMP im
# Container das Problem, nicht das Netz — dann sagt der Report das, statt
# eine leere Geräteliste zu behaupten. NICHT .33 nehmen: die liegt auf dem
# macvlan-Eltern-Interface, und macvlan-Kinder erreichen ihren Wirt
# prinzipbedingt nicht — .33 fehlt in dieser Liste deshalb IMMER.
REFERENCE_IP="$SUBNET.150"

# ── Wachliste: sind BESTIMMTE Geräte an? ──────────────────────────────────
# Der eigentliche Ursprungszweck dieses Monitors. Ergebnis wandert doppelt:
# als Tile aufs Board und als erste Sektion in den Report. Die Tabelle
# selbst (samt Felddoku) liegt in monitor-watch.conf: Beispielwerte im
# Repo, die deployte Kopie hält die echten Geräte (twin `Own:`) — wie bei
# config/milan.yaml.
source "$(dirname "$0")/monitor-watch.conf"
device_up() { # ip vantage
  if [[ "$2" == "mini" ]]; then
    [[ "$(curl -sf -m 12 "http://192.168.1.118:8080/reach/$1" 2>/dev/null)" == ok* ]]
  else
    ping -c 2 -W 1 "$1" >/dev/null 2>&1
  fi
}
WATCH_OUT=$(mktemp)
for target in "${!WATCH[@]}"; do
  IFS=':' read -r label ip mode vantage <<< "${WATCH[$target]}"
  if device_up "$ip" "$vantage"; then
    echo "🟢 $label (\`$ip\`) — an" >> "$WATCH_OUT"
    watch_push+=("$target|$label|A3BE8C|check|an")
  elif [[ "$mode" == "soll-an" ]]; then
    echo "🟠 $label (\`$ip\`) — aus, sollte laufen" >> "$WATCH_OUT"
    watch_push+=("$target|$label|EBCB8B|warn|aus, sollte laufen")
  else
    echo "⚪ $label (\`$ip\`) — aus" >> "$WATCH_OUT"
    watch_push+=("$target|$label|4C566A||aus")
  fi
done

# ── Sweep: aktive Geräte im /24 ───────────────────────────────────────────
SWEEP_TMP=$(mktemp)
for i in $(seq 1 254); do
  ( ping -c 1 -W 1 "$SUBNET.$i" >/dev/null 2>&1 && echo "$SUBNET.$i" >> "$SWEEP_TMP" ) &
done
wait

{
  echo "## Wache"
  echo
  sort "$WATCH_OUT"
  echo
  if ! grep -q "^$REFERENCE_IP$" "$SWEEP_TMP"; then
    echo "⚠ Sweep unglaubwürdig: Referenz $REFERENCE_IP antwortet nicht —"
    echo "vermutlich darf der Container kein ICMP. Geräteliste nicht verlässlich."
    echo
  fi
  echo "## Aktive Geräte ($(wc -l < "$SWEEP_TMP" | tr -d ' '))"
  echo
  sort -t. -k4 -n "$SWEEP_TMP" | while read -r ip; do
    # Nur das erste Label: der Container-Resolver hängt die Tailscale-Domain
    # an, und ein PTR-loses Gerät kommt als seine eigene IP zurück.
    name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}')
    name="${name%%.*}"
    [[ "$name" == "${ip%%.*}" || "$name" == "$ip" ]] && name=""
    echo "- \`$ip\` ${name:+— $name}"
  done
} > "$TMP_OUTPUT"
rm -f "$SWEEP_TMP" "$WATCH_OUT"

# ── LiveSync-Wächter (headless Daemons; Board-Tiles + Auto-Restart) ───────
# Fragt beide Macs via mi.lan /livesync ab. Neustart bei Crash ODER Uptime
# >= Schwellwert (gegen den chokidar/Listener-Leak, der den Watcher erst
# über Tage stilllegt → 24h, nicht schon beim frühen Warn-Flag).
#
# Anzeige NUR noch als Board-Tiles (livesync-mini/-book, TTL 20 min beim
# 5-Minuten-Takt): ein unerreichbarer Mac wird nicht gepusht — ein
# schlafendes Book wäre sonst Dauer-Gelb — seine Kachel vergraut von
# selbst. Farben: Nord, wie überall.
RESTART_UPTIME_H=24
MILAN_WIDGET="http://192.168.1.118:8080/widget"

push_tile() { # target title color icon text
  local target="$1" title="$2" color="$3" icon="$4" text="$5"
  curl -s -m 5 -X POST --data-binary "$text" \
    "$MILAN_WIDGET/$target?title=$(echo "$title" | sed 's/ /%20/g')&icon=$icon&color=%23$color&ttl=1200" \
    >/dev/null 2>&1 || true
}

# Wachlisten-Tiles (gesammelt oben, gepusht hier — nach der Definition).
for entry in "${watch_push[@]}"; do
  IFS='|' read -r target label color icon text <<< "$entry"
  push_tile "$target" "$label" "$color" "$icon" "$text"
done

# Neustart anfordern und die Antwort NICHT wegwerfen. livesync-restart.rb
# meldet Fehlschläge im Klartext, und genau die gingen am 2026-08-01 zwanzig
# Stunden lang ins Leere (622 Aufrufe, "you do not exist in the passwd
# database"). Ein fehlgeschlagener Neustart überschreibt deshalb das Tile —
# das letzte Wort auf dem Board ist die Wahrheit.
request_restart() {
  local ip="$1" target="$2" r
  r=$(curl -s --max-time 30 "http://$ip:8080/livesync-restart" 2>&1)
  if [[ -z "$r" ]]; then
    push_tile "livesync-$target" "LiveSync $target" BF616A warn "Neustart-Aufruf ohne Antwort (milan erreichbar?)"
  elif [[ "$r" == *"⚠"* ]]; then
    r="${r#*⚠ }"
    push_tile "livesync-$target" "LiveSync $target" BF616A warn "Neustart fehlgeschlagen: ${r:0:120}"
  fi
}

for entry in "mini:192.168.1.118" "book:192.168.1.187"; do
  t="${entry%%:*}"; ip="${entry##*:}"
  out=$(curl -sf --max-time 10 "http://$ip:8080/livesync" 2>/dev/null)
  [[ -z "$out" ]] && continue   # schläft/weg → kein Push, Tile vergraut

  up_h=$(echo "$out" | grep -oE "Uptime [0-9]+h" | grep -oE "[0-9]+" | head -1)
  if echo "$out" | grep -q "gesperrt"; then
    # Remote-DB gesperrt (z. B. nach iPhone-Rebuild/Doctor) — Neustart hilft
    # NICHT, nur anzeigen.
    push_tile "livesync-$t" "LiveSync $t" EBCB8B warn "Remote gesperrt, Unlock nötig"
  elif echo "$out" | grep -qiE "Crash|cannot be initialised|OpenError"; then
    push_tile "livesync-$t" "LiveSync $t" BF616A warn "Crash, Neustart angefordert"
    request_restart "$ip" "$t"
  elif [[ -n "$up_h" && "$up_h" -ge "$RESTART_UPTIME_H" ]]; then
    push_tile "livesync-$t" "LiveSync $t" EBCB8B warn "Uptime ${up_h}h, praeventiver Neustart"
    request_restart "$ip" "$t"
  elif echo "$out" | grep -q "gesund"; then
    push_tile "livesync-$t" "LiveSync $t" A3BE8C check "gesund, Uptime ${up_h:-?}h"
  else
    push_tile "livesync-$t" "LiveSync $t" EBCB8B warn "Achtung, Detail unter /livesync"
  fi
done

# ── Footer + atomic publish ───────────────────────────────────────────────
{
  echo
  echo "Last update: $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$TMP_OUTPUT"

mv "$TMP_OUTPUT" "$OUTPUT"
