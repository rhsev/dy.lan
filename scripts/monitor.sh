#!/bin/bash
# Network Monitor — generates a Markdown report of ACTIVE devices on the LAN
# and writes it to /app/data/monitor.md. The Dylan plugin serves the file as
# text/plain; Stage (Output-Box) and direct /monitor visits see the same text.
#
# Two sections since 2026-08-27: the WATCH (are specific devices up — the
# original purpose; VMs, also as board tiles) and the SWEEP (who answers in
# the /24 right now, with PTR names — the lookup view). The old services
# section (milan ports) is covered by /probe and the Stage badges; the
# LiveSync lines live on as board tiles — this script remains their WATCHDOG
# (below).
#
# Cron schedule: config/crontab (every 5 minutes).
#
# Robustness:
#   - Atomic write via temp file + mv: readers never see a half-written file,
#     and the previous monitor.md stays available for the length of a run.
#   - TZ set explicitly: cronie does not necessarily inherit the container
#     environment, and `date` would print UTC.

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
REFERENCE_IP="${REFERENCE_IP:-$SUBNET.20}"

# Base URL of the milan agent that acts as this monitor's vantage point on the
# LAN — used for reachability probes and for pushing board tiles.
MILAN_URL="${MILAN_URL:-http://localhost:8080}"

# Hosts whose headless LiveSync daemon this monitor watches: "name:base-url".
# `declare -a` keeps an array the conf already set and creates an empty one
# otherwise, so a conf predating this key cannot break the loop below.
declare -a LIVESYNC_AGENTS

# ── Watch list: are SPECIFIC devices up? ─────────────────────────────────
# The original purpose of this monitor. The result goes two ways: a tile on
# the board and the first section of the report. The table itself, field
# documentation included, sits in monitor-watch.conf next to the addresses.
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
    watch_result+=("$target|$label|$ip|up")
  elif [[ "$mode" == "soll-an" ]]; then
    echo "🟠 $label (\`$ip\`) — aus, sollte laufen" >> "$WATCH_OUT"
    watch_push+=("$target|$label|EBCB8B|warn|aus, sollte laufen")
    watch_result+=("$target|$label|$ip|down")
  else
    echo "⚪ $label (\`$ip\`) — aus" >> "$WATCH_OUT"
    watch_push+=("$target|$label|4C566A||aus")
    watch_result+=("$target|$label|$ip|down")
  fi
done

# ── Outage alerts: say it when a watched device STOPS answering ───────────
# Only the outage. A recovery says nothing: the board tile already shows the
# present, and the ntfy topic is meant to be read as the log of what broke
# and when — a stream of "back again" lines would bury that.
#
# Debounced, and that is the whole point. The probe is two pings inside one
# second, which a Wi-Fi device in power save drops often enough. An outage
# counts as real only after two consecutive failed cycles (10 minutes);
# without that the topic fills with flapping nobody reads.
#
# State: one line per tile in data/watch_state.txt — "id:state:fails".
# A tile whose previous state is unknown never alerts on the first sighting,
# or a fresh container would report the whole watch list as newly broken.
# Which tile alerts on which topic is configured in monitor-watch.conf; a
# tile that is not listed there is watched on the board only.
declare -A ALERT 2>/dev/null
ALERT_STATE="${MONITOR_STATE:-/app/data/watch_state.txt}"
ALERT_FAILS_REQUIRED=2

alert_ntfy() { # topic title text
  [[ -n "$NTFY_URL" ]] || return 0
  curl -s -m 5 -X POST --data-binary "$3" \
    -H "Title: $2" -H "Tags: warning" -H "Priority: high" \
    "${NTFY_URL%/}/$1" >/dev/null 2>&1 || true
}

declare -A ALERT_PREV ALERT_FAILS
if [[ -f "$ALERT_STATE" ]]; then
  while IFS=':' read -r sid sstate sfails; do
    [[ -n "$sid" ]] || continue
    ALERT_PREV["$sid"]="$sstate"
    ALERT_FAILS["$sid"]="$sfails"
  done < "$ALERT_STATE"
fi

ALERT_TMP="${ALERT_STATE}.tmp"
: > "$ALERT_TMP"
for entry in "${watch_result[@]}"; do
  IFS='|' read -r target label ip result <<< "$entry"
  prev="${ALERT_PREV[$target]:-unknown}"
  fails="${ALERT_FAILS[$target]:-0}"
  if [[ "$result" == "up" ]]; then
    state="online"
    fails=0
  else
    fails=$((fails + 1))
    if (( fails >= ALERT_FAILS_REQUIRED )); then
      state="offline"
      if [[ "$prev" != "offline" && -n "${ALERT[$target]:-}" ]]; then
        alert_ntfy "${ALERT[$target]}" "$label ausgefallen" \
          "$label ($ip) antwortet seit mindestens $((fails * 5)) Minuten nicht. $(date '+%d.%m. %H:%M')"
      fi
    else
      # One miss is not an outage: keep the old verdict, count the failure.
      state="$prev"
    fi
  fi
  printf '%s:%s:%s\n' "$target" "$state" "$fails" >> "$ALERT_TMP"
done
mv "$ALERT_TMP" "$ALERT_STATE"

# ── Sweep: which devices answer in the /24 ───────────────────────────────
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
    # First label only: the container resolver appends the tailscale domain,
    # and a device without a PTR record comes back as its own address.
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

# Watch-list tiles: collected above, pushed here — after push_tile exists.
for entry in "${watch_push[@]}"; do
  IFS='|' read -r target label color icon text <<< "$entry"
  push_tile "$target" "$label" "$color" "$icon" "$text"
done

# Request a restart and do NOT throw the answer away. livesync-restart.rb
# reports failures in plain words, and those were exactly what went nowhere
# for twenty hours on 2026-08-01 (622 calls, "you do not exist in the passwd
# database"). A failed restart therefore overwrites the tile — the last word
# on the board is the truth.
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
  [[ -z "$out" ]] && continue   # asleep or away → no push, the tile greys out

  up_h=$(echo "$out" | grep -oE "Uptime [0-9]+h" | grep -oE "[0-9]+" | head -1)
  if echo "$out" | grep -q "gesperrt"; then
    # Remote database locked (e.g. after an iPhone rebuild or doctor run) —
    # a restart does NOT help here, so only report it.
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
