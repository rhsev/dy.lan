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

# ── Footer + atomic publish + write status file ──────────────────────────
{
  echo
  echo "Last update: $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$TMP_OUTPUT"

# Atomic publish: mv ist atomar innerhalb desselben Filesystems, Reader sehen
# entweder die alte oder die neue Datei — nie eine halbgeschriebene.
mv "$TMP_OUTPUT" "$OUTPUT"

echo "$new_status" > "$STATUS_FILE"
