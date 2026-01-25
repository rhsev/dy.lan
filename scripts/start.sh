#!/bin/bash
set -e

echo "==> Starting Dylan Server with Cron support"

# Create cache directory for crontab
mkdir -p /root/.cache

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
