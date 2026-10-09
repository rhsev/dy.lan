#!/bin/bash
set -e

echo "==> Starting Dylan Server with Cron support"

# Create cache directory for crontab
mkdir -p /root/.cache

# Install crontab from config (supports volume-mounted config/)
# Tolerate a bad crontab line: never let it abort startup (set -e) and crash-loop the container.
crontab /app/config/crontab || echo "WARN: crontab abgelehnt"

# Start cron in background
echo "==> Starting crond..."
crond -s &

# Give cron a moment to start
sleep 1

# Show loaded crontab for verification
echo "==> Loaded crontab:"
crontab -l

# Start Dylan server in foreground
echo "==> Starting Dylan HTTP Server..."
exec ruby /app/server.rb
