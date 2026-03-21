#!/bin/bash
# Arche Environment — Configuration
# Edit these values, then run: sudo ./flash.sh

# ── Target Board ────────────────────────────────────
BOARD="${BOARD:-jetson-orin-nano-devkit}"

# ── L4T / JetPack Version ──────────────────────────
L4T_VERSION="${L4T_VERSION:-36.3.0}"
JETPACK_VERSION="${JETPACK_VERSION:-6.0}"

# ── Default User ────────────────────────────────────
DEFAULT_USERNAME="${DEFAULT_USERNAME:-jetson}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-jetson}"

# ── Flash Command ───────────────────────────────────
FLASH_CMD="sudo BOARDSKU=0000 ./flash.sh --no-flash ${BOARD} mmcblk0p1" # Simple test command

# Override this for different boot targets (eMMC, NVMe, SD, etc.)
# FLASH_CMD="${FLASH_CMD:-sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
#   --external-device nvme0n1p1 \
#   -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
#   -p \"-c bootloader/generic/cfg/flash_t234_qspi.xml\" \
#   --shetwork usb0 --noflash\
#   ${BOARD} internal}"

# ── Derived Paths (do not edit) ─────────────────────
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${WORKSPACE_DIR}/scripts"
WORK_DIR="${WORKSPACE_DIR}/workdir/Linux_for_Tegra"
ROOTFS_DIR="${WORK_DIR}/rootfs"
DOWNLOAD_DIR="${WORKSPACE_DIR}/workdir/downloads"
STAMP_DIR="${ROOTFS_DIR}/etc/jetson-build/.stamps"
BUILD_MANIFEST="${ROOTFS_DIR}/etc/jetson-build/build-info"

BSP_URL="https://developer.nvidia.com/downloads/embedded/L4T/r36_Release_v3.0/release/Jetson_Linux_R${L4T_VERSION}_aarch64.tbz2"
ROOTFS_URL="https://developer.nvidia.com/downloads/embedded/L4T/r36_Release_v3.0/release/Tegra_Linux_Sample-Root-Filesystem_R${L4T_VERSION}_aarch64.tbz2"
