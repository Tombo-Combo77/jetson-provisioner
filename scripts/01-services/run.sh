#!/bin/bash
# Disable services that are unnecessary on a headless/embedded Jetson.
# Comment out lines to keep specific services.
set -e

DISABLE=(
    apt-daily.timer
    apt-daily-upgrade.timer
    motd-news.timer
    unattended-upgrades
)

for svc in "${DISABLE[@]}"; do
    systemctl disable "${svc}" 2>/dev/null && echo "  disabled ${svc}" || true
    systemctl mask    "${svc}" 2>/dev/null || true
done

echo "✓ Services configured"
