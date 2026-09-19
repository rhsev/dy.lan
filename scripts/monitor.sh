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

# Overridable so the script can be dry-run outside the container.
OUTPUT="${MONITOR_OUTPUT:-/app/data/monitor.md}"
TMP_OUTPUT="${OUTPUT}.tmp"

# ── Settings ──────────────────────────────────────────────────────────────
# Every address this monitor needs lives in monitor-watch.conf, never in this
# file: the repo copy carries example values, the deployed copy owns the real
# ones and is never overwritten by a sync (twin `Exclude`) — same split as
# config/milan.yaml. The defaults below only keep the script runnable when a
# key is missing; they are not anybody's network.
source "$(dirname "$0")/monitor-watch.conf"

SUBNET="${SUBNET:-192.168.1}"
# Known-live reference: if it does not answer the sweep, ICMP inside the
# container is the problem, not the network — and the report says so instead
# of claiming an empty device list. Do NOT use the docker host's own address:
# it sits on the macvlan parent interface, and macvlan children cannot reach
# their host by design, so it is ALWAYS missing from the sweep.
REFERENCE_IP="${REFERENCE_IP:-$SUBNET.150}"

# Base URL of the milan agent that acts as this monitor's vantage point on the
# LAN — used for reachability probes and for pushing board tiles.
MILAN_URL="${MILAN_URL:-http://localhost:8080}"

# Hosts whose headless LiveSync daemon this monitor watches: "name:base-url".
# `declare -a` keeps an array the conf already set and creates an empty one
# otherwise, so a conf predating this key cannot break the loop below.
declare -a LIVESYNC_AGENTS

# ── Wachliste: sind BESTIMMTE Geräte an? ──────────────────────────────────
# Der eigentliche Ursprungszweck dieses Monitors. Ergebnis wandert doppelt:
# als Tile aufs Board und als erste Sektion in den Report. Die Tabelle selbst
# (samt Felddoku) liegt in monitor-watch.conf, zusammen mit den Adressen.
#
# A device on the `mini` vantage point is probed through the milan agent
# rather than from here: the container cannot see every corner of the LAN.
device_up() { # ip vantage
  if [[ "$2" == "mini" ]]; then
    [[ "$(curl -sf -m 12 "$MILAN_URL/reach/$1" 2>/dev/null)" == ok* ]]
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

# ── LiveSync watchdog (headless daemons; board tiles + auto restart) ──────
# Asks every host in LIVESYNC_AGENTS via mi.lan /livesync. Restart on crash OR
# on uptime >= threshold (against the chokidar/listener leak that only
# silences the watcher after days → 24h, not at the first warning flag).
#
# One board tile per host, TTL 20 min against the 5-minute cadence. An
# unreachable host is not pushed at all — a sleeping laptop would otherwise be
# permanently yellow — and its tile greys out by itself. Colours: Nord.
#
# Lesson from 2026-09-16: take a host OUT of the list the moment it leaves
# LiveSync. Its tile is then never overwritten again and stays on the board as
# a red corpse carrying the last error message, while the watchdog keeps
# requesting a restart of something that no longer exists.
RESTART_UPTIME_H=24
MILAN_WIDGET="$MILAN_URL/widget"

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
  local url="$1" target="$2" r
  r=$(curl -s --max-time 30 "$url/livesync-restart" 2>&1)
  if [[ -z "$r" ]]; then
    push_tile "livesync-$target" "LiveSync $target" BF616A warn "Neustart-Aufruf ohne Antwort (milan erreichbar?)"
  elif [[ "$r" == *"⚠"* ]]; then
    r="${r#*⚠ }"
    push_tile "livesync-$target" "LiveSync $target" BF616A warn "Neustart fehlgeschlagen: ${r:0:120}"
  fi
}

# Entries are "name:base-url"; the list lives in monitor-watch.conf. Empty is
# a legitimate state (no host runs LiveSync) — say so rather than looking as
# if the section had run.
if [[ ${#LIVESYNC_AGENTS[@]} -eq 0 ]]; then
  echo "_LiveSync: keine Hosts konfiguriert (LIVESYNC_AGENTS)._" >> "$TMP_OUTPUT"
fi
for entry in "${LIVESYNC_AGENTS[@]}"; do
  t="${entry%%:*}"; url="${entry#*:}"
  out=$(curl -sf --max-time 10 "$url/livesync" 2>/dev/null)
  [[ -z "$out" ]] && continue   # schläft/weg → kein Push, Tile vergraut

  up_h=$(echo "$out" | grep -oE "Uptime [0-9]+h" | grep -oE "[0-9]+" | head -1)
  if echo "$out" | grep -q "gesperrt"; then
    # Remote-DB gesperrt (z. B. nach iPhone-Rebuild/Doctor) — Neustart hilft
    # NICHT, nur anzeigen.
    push_tile "livesync-$t" "LiveSync $t" EBCB8B warn "Remote gesperrt, Unlock nötig"
  elif echo "$out" | grep -qiE "Crash|cannot be initialised|OpenError"; then
    push_tile "livesync-$t" "LiveSync $t" BF616A warn "Crash, Neustart angefordert"
    request_restart "$url" "$t"
  elif [[ -n "$up_h" && "$up_h" -ge "$RESTART_UPTIME_H" ]]; then
    push_tile "livesync-$t" "LiveSync $t" EBCB8B warn "Uptime ${up_h}h, praeventiver Neustart"
    request_restart "$url" "$t"
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
