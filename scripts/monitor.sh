#!/bin/bash
# Network Monitor — generates a Markdown status report and writes it to
# /app/data/monitor.md. The Dylan plugin serves the file as text/plain;
# both Stage (Output-Box) and direct browser visits (via /monitor) see
# the same Markdown-formatted text.
#
# Cron schedule: see config/crontab (default every 5 minutes).

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

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
} > "$OUTPUT"

new_status=""

# ── Hosts (ping) ──────────────────────────────────────────────────────────
for name in "${!hosts[@]}"; do
  ip="${hosts[$name]}"
  last_status=$(get_last_status "$ip")

  if ping -c 3 -w 5 "$ip" 2>/dev/null | grep -q "bytes from"; then
    current_status="online"
    echo "- 🟢 $name (\`$ip\`)" >> "$OUTPUT"
  else
    current_status="offline"
    echo "- 🟠 $name (\`$ip\`) — offline" >> "$OUTPUT"
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
} >> "$OUTPUT"

for name in "${!services[@]}"; do
  addr="${services[$name]}"
  host="${addr%:*}"
  port="${addr#*:}"
  last_status=$(get_last_status "$addr")

  if check_port "$host" "$port"; then
    current_status="online"
    echo "- 🟢 $name (\`$addr\`)" >> "$OUTPUT"
  else
    current_status="offline"
    echo "- 🟠 $name (\`$addr\`) — offline" >> "$OUTPUT"
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

# ── Footer + write status file ────────────────────────────────────────────
{
  echo
  echo "_Last update: $(date '+%Y-%m-%d %H:%M:%S')_"
} >> "$OUTPUT"

echo "$new_status" > "$STATUS_FILE"
