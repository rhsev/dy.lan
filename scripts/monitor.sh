#!/bin/bash

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Am Anfang vom Script als Config-Variable
NTFY_TOPIC="mytopic"  # Change to your ntfy.sh topic

# Define hosts to monitor
declare -A hosts=(
  ["CachyOS VM"]="192.168.1.152"
  ["Fedora"]="192.168.1.73"
  ["Steckdose Bad"]="192.168.1.55"
)

# File paths
OUTPUT="/app/data/monitor.html"
STATUS_FILE="/app/data/monitor_status.txt"

# Function: Read last status from status file
get_last_status() {
  local ip="$1"
  if [[ -f "$STATUS_FILE" ]]; then
    grep "^$ip:" "$STATUS_FILE" 2>/dev/null | cut -d: -f2
  fi
}

# HTML header
cat > "$OUTPUT" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta http-equiv='refresh' content='30'>
  <title>Netzwerk Monitor</title>
  <style>
    body { 
      font-family: Arial, sans-serif; 
      margin: 20px; 
      background-color: #f5f5f5;
    }
    h1 { color: #333; }
    table { 
      border-collapse: collapse; 
      width: 100%; 
      background-color: white;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    th, td { 
      border: 1px solid #ddd; 
      padding: 12px; 
      text-align: left; 
    }
    th { 
      background-color: #4CAF50; 
      color: white; 
    }
    tr:hover { background-color: #f5f5f5; }
  </style>
</head>
<body>
<h1>Netzwerk Monitor</h1>
<table>
<tr><th>Status</th><th>Service</th><th>IP</th></tr>
EOF

# Variable for new status file
new_status=""

# Check hosts
for name in "${!hosts[@]}"; do
  ip="${hosts[$name]}"

  # 1. Read last status from status file
  last_status=$(get_last_status "$ip")

  # 2. Determine current status
  if ping -c 1 -w 1 "$ip" > /dev/null 2>&1; then
    current_status="online"
    echo "<tr><td>&#x1F7E2; Online</td><td>$name</td><td>$ip</td></tr>" >> "$OUTPUT"
  else
    current_status="offline"
    echo "<tr><td>&#x1F534; OFFLINE</td><td>$name</td><td>$ip</td></tr>" >> "$OUTPUT"
  fi

  # Collect status for new status file
  new_status+="$ip:$current_status"$'\n'

  # 3. Notify only on status change
  if [[ "$last_status" != "$current_status" ]]; then
    if [[ "$current_status" == "offline" ]]; then
      curl -s -d "$name ($ip) ist offline!" ntfy.sh/$NTFY_TOPIC > /dev/null 2>&1
    else
      curl -s -d "$name ($ip) ist wieder online!" ntfy.sh/$NTFY_TOPIC > /dev/null 2>&1
    fi
  fi
done

# HTML footer
cat >> "$OUTPUT" << 'EOF'
</table>
<p style="color: #666; font-size: 12px;">
Letzte Aktualisierung: 
EOF
date >> "$OUTPUT"
echo "</p></body></html>" >> "$OUTPUT"

# Write new status file (at the end!)
echo "$new_status" > "$STATUS_FILE"
