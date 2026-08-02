#!/bin/bash
# Network Monitor — generates a Markdown status report and writes it to
# /app/data/monitor.md. The Dylan plugin serves the file as text/plain;
# both Stage (Output-Box) and direct browser visits (via /monitor) see
# the same Markdown-formatted text.
#
# Cron schedule: see config/crontab (default every 5 minutes).
#
# Robustheit:
#   - Atomic write via temp file + mv: Reader sehen nie eine halb-geschriebene
#     Datei. Während die Pings laufen (~5-30s pro Run) bleibt die alte
#     monitor.md verfügbar.
#   - TZ explizit setzen: Cronie erbt nicht zwingend die Container-ENV-Variablen,
#     daher würde `date` sonst UTC ausgeben.

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ="${TZ:-Europe/Berlin}"

# Notification config
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="mytopic"

# Define hosts to monitor (ping check)
declare -A hosts=(
  ["CachyOS VM"]="192.168.1.152"
  ["Fedora"]="192.168.1.73"
  ["Steckdose Bad"]="192.168.1.55"
)

# Define services to monitor (port check). Format: ["Name"]="host:port"
declare -A services=(
  ["Milan Mini"]="192.168.1.118:8080"
  ["Milan Book"]="192.168.1.195:8080"
)

OUTPUT="/app/data/monitor.md"
TMP_OUTPUT="${OUTPUT}.tmp"
STATUS_FILE="/app/data/monitor_status.txt"

# Read previous status of an address from the status file
get_last_status() {
  local addr="$1"
  if [[ -f "$STATUS_FILE" ]]; then
    grep "^${addr}:" "$STATUS_FILE" 2>/dev/null | awk -F: '{print $NF}'
  fi
}

check_port() {
  local host="$1" port="$2"
  timeout 2 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
}

# Begin output (overwrite)
{
  echo "## Hosts"
  echo
} > "$TMP_OUTPUT"

new_status=""

# ── Hosts (ping) ──────────────────────────────────────────────────────────
for name in "${!hosts[@]}"; do
  ip="${hosts[$name]}"
  last_status=$(get_last_status "$ip")

  if ping -c 3 -w 5 "$ip" 2>/dev/null | grep -q "bytes from"; then
    current_status="online"
    echo "🟢 $name (\`$ip\`)" >> "$TMP_OUTPUT"
  else
    current_status="offline"
    echo "🟠 $name (\`$ip\`) — offline" >> "$TMP_OUTPUT"
  fi

  new_status+="$ip:$name:$current_status"$'\n'

  # Status-change notification
  if [[ "$last_status" != "$current_status" ]]; then
    if [[ "$current_status" == "offline" ]]; then
      curl -s --max-time 5 -d "$name ($ip) ist offline!" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1
    else
      curl -s --max-time 5 -d "$name ($ip) ist wieder online!" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1
    fi
  fi
done

# ── Services (port check) ─────────────────────────────────────────────────
{
  echo
  echo "## Services"
  echo
} >> "$TMP_OUTPUT"

for name in "${!services[@]}"; do
  addr="${services[$name]}"
  host="${addr%:*}"
  port="${addr#*:}"
  last_status=$(get_last_status "$addr")

  if check_port "$host" "$port"; then
    current_status="online"
    echo "🟢 $name (\`$addr\`)" >> "$TMP_OUTPUT"
  else
    current_status="offline"
    echo "🟠 $name (\`$addr\`) — offline" >> "$TMP_OUTPUT"
  fi

  new_status+="$addr:$name:$current_status"$'\n'

  if [[ "$last_status" != "$current_status" ]]; then
    if [[ "$current_status" == "offline" ]]; then
      curl -s --max-time 5 -d "$name ($addr) ist offline!" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1
    else
      curl -s --max-time 5 -d "$name ($addr) ist wieder online!" "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null 2>&1
    fi
  fi
done

# ── LiveSync (headless Daemons; Status + bedingter Auto-Restart) ──────────
# Fragt beide Macs via mi.lan /livesync ab, schreibt den Status in den Report.
# Neustart auslösen bei Crash (🔴) ODER Uptime >= Schwellwert (gegen den
# chokidar/Listener-Leak, der den Watcher erst über Tage stilllegt → 24h,
# nicht schon beim frühen Warn-Flag). Läuft auf dem zuverlässigen */5-Takt,
# kein TZ-Problem wie bei einer Stunden-Cron-Zeile.
RESTART_UPTIME_H=24

# Neustart anfordern und die Antwort NICHT wegwerfen. livesync-restart.rb meldet
# Fehlschläge im Klartext ("⚠ Neustart fehlgeschlagen — …"), und genau die gingen
# am 2026-08-01 zwanzig Stunden lang ins Leere: 622 Aufrufe, jedes Mal
# "sudo: you do not exist in the passwd database", sichtbar nur als stetig
# steigende Uptime. Ein fehlgeschlagener Neustart muss im Report stehen.
request_restart() {
  local ip="$1" name="$2" r
  r=$(curl -s --max-time 30 "http://$ip:8080/livesync-restart" 2>&1)
  if [[ -z "$r" ]]; then
    echo "⚠ LiveSync $name — Neustart-Aufruf ohne Antwort (milan erreichbar?)" >> "$TMP_OUTPUT"
  elif [[ "$r" == *"⚠"* ]]; then
    r="${r#⚠ }"                 # eigene Markierung vorn, Meldung dahinter
    echo "⚠ LiveSync $name — ${r:0:160}" >> "$TMP_OUTPUT"
  fi
}
{
  echo
  echo "## LiveSync"
  echo
} >> "$TMP_OUTPUT"

for entry in "Mini:192.168.1.118" "Book:192.168.1.195"; do
  name="${entry%%:*}"; ip="${entry##*:}"
  out=$(curl -sf --max-time 10 "http://$ip:8080/livesync" 2>/dev/null)
  if [[ -z "$out" ]]; then
    echo "⚪ LiveSync $name — milan nicht erreichbar" >> "$TMP_OUTPUT"
    continue
  fi
  up_h=$(echo "$out" | grep -oE "Uptime [0-9]+h" | grep -oE "[0-9]+" | head -1)
  if echo "$out" | grep -q "gesperrt"; then
    # Remote-DB gesperrt (z. B. nach iPhone-Rebuild/Doctor) — Neustart hilft NICHT, nur anzeigen.
    echo "🔒 LiveSync $name — Remote gesperrt, Unlock nötig (kein Neustart)" >> "$TMP_OUTPUT"
  elif echo "$out" | grep -qiE "Crash|cannot be initialised|OpenError"; then
    echo "🔴 LiveSync $name — Crash → Neustart" >> "$TMP_OUTPUT"
    request_restart "$ip" "$name"
  elif [[ -n "$up_h" && "$up_h" -ge "$RESTART_UPTIME_H" ]]; then
    echo "🟠 LiveSync $name — Uptime ${up_h}h → präventiver Neustart" >> "$TMP_OUTPUT"
    request_restart "$ip" "$name"
  elif echo "$out" | grep -q "gesund"; then
    echo "🟢 LiveSync $name (${up_h:-?}h)" >> "$TMP_OUTPUT"
  else
    echo "🟠 LiveSync $name — Achtung (Detail: Button /livesync)" >> "$TMP_OUTPUT"
  fi
done

# ── Footer + atomic publish + write status file ──────────────────────────
{
  echo
  echo "Last update: $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$TMP_OUTPUT"

# Atomic publish: mv ist atomar innerhalb desselben Filesystems, Reader sehen
# entweder die alte oder die neue Datei — nie eine halbgeschriebene.
mv "$TMP_OUTPUT" "$OUTPUT"

echo "$new_status" > "$STATUS_FILE"
