#!/bin/bash
# Install common packages into the Jetson rootfs.
# Add or remove packages from the list below.
set -e

# Remove broken NVIDIA repos from sample rootfs (contains <SOC> placeholder)
rm -f /etc/apt/sources.list.d/nvidia-l4t-apt-source.list
find /etc/apt/sources.list.d/ -type f \( -name "*nvidia*" -o -name "*jetson*" \) -delete 2>/dev/null || true

apt-get update
apt-get install -y --no-install-recommends \
    curl \
    htop \
    nano \
    net-tools \
    openssh-server

echo "✓ Packages installed"
