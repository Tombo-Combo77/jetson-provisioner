#!/bin/bash
set -e

# ════════════════════════════════════════════════════
#  Arche Environment — Jetson Provisioning Pipeline
# ════════════════════════════════════════════════════
#  Runs the full pipeline from dependency check through
#  flash, picking up where it left off on re-run.
#
#  Usage:
#    sudo ./flash.sh            # full pipeline
#    sudo ./flash.sh --clean    # wipe workdir, start over
# ════════════════════════════════════════════════════

source "$(dirname "$0")/config.sh"

HOST_ARCH="$(uname -m)"  # x86_64 or aarch64

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root (sudo ./flash.sh)" >&2
    exit 1
fi

# ── --clean ─────────────────────────────────────────

if [ "$1" = "--clean" ]; then
    echo "Cleaning workdir..."
    for mnt in "${ROOTFS_DIR}"/{etc/resolv.conf,tmp,run,sys,proc,dev/pts,dev}; do
        umount "${mnt}" 2>/dev/null || true
    done
    rm -rf "${WORKSPACE_DIR}/workdir"
    echo "✓ Clean. Run again to rebuild."
    exit 0
fi

echo "=========================================="
echo "  Arche Environment"
echo "=========================================="
echo "  Board:    ${BOARD}"
echo "  L4T:      ${L4T_VERSION}"
echo "  JetPack:  ${JETPACK_VERSION}"
echo "  User:     ${DEFAULT_USERNAME}"
echo "=========================================="
echo ""

# ────────────────────────────────────────────────────
#  Chroot helpers — called in Phase 5
# ────────────────────────────────────────────────────
#  These install shims that make cross-arch package
#  installation work inside chroot, and remove them
#  cleanly afterward so the rootfs is never left with
#  host-specific artifacts.
# ────────────────────────────────────────────────────

QEMU_COPIED=false

setup_chroot() {
    local rootfs="$1"

    if [ "${HOST_ARCH}" = "x86_64" ]; then
        # Copy QEMU binary for ARM64 emulation (only needed on x86 hosts)
        cp /usr/bin/qemu-aarch64-static "${rootfs}/usr/bin/"
        QEMU_COPIED=true
    fi

    # Block service starts during package installs
    printf '#!/bin/bash\nexit 101\n' > "${rootfs}/usr/sbin/policy-rc.d"
    chmod +x "${rootfs}/usr/sbin/policy-rc.d"

    # Wrap systemctl: allow enable/disable, block start/stop
    if [ -f "${rootfs}/bin/systemctl" ] && [ ! -f "${rootfs}/bin/systemctl.orig" ]; then
        cp "${rootfs}/bin/systemctl" "${rootfs}/bin/systemctl.orig"
        cat > "${rootfs}/bin/systemctl" <<'SHIM'
#!/bin/bash
case "$1" in
    start|stop|restart|reload|try-restart|reload-or-restart)
        echo "systemctl $* (skipped in chroot)" ; exit 0 ;;
    enable|disable|mask|unmask)
        exec /bin/systemctl.orig "$@" ;;
    *)
        exec /bin/systemctl.orig "$@" 2>/dev/null || true ;;
esac
SHIM
        chmod +x "${rootfs}/bin/systemctl"
    fi

    # Divert mandb to avoid slow triggers
    chroot "${rootfs}" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        dpkg-divert --local --rename --add /usr/bin/mandb 2>/dev/null || true
    chroot "${rootfs}" ln -sf /bin/true /usr/bin/mandb 2>/dev/null || true

    # Locale stub
    echo "en_US.UTF-8 UTF-8" > "${rootfs}/etc/locale.gen"

    # Bind-mount host kernel interfaces
    mkdir -p "${rootfs}"/{dev,dev/pts,proc,sys,tmp,run}
    mount --bind /dev     "${rootfs}/dev"
    mount --bind /dev/pts "${rootfs}/dev/pts" 2>/dev/null || true
    mount --bind /proc    "${rootfs}/proc"
    mount --bind /sys     "${rootfs}/sys"
    mount -t tmpfs tmpfs  "${rootfs}/run"     2>/dev/null || mount --bind /run "${rootfs}/run"
    mount -t tmpfs tmpfs  "${rootfs}/tmp"     2>/dev/null || true

    # DNS resolution inside chroot
    if [ -f /etc/resolv.conf ]; then
        rm -f "${rootfs}/etc/resolv.conf"
        touch "${rootfs}/etc/resolv.conf"
        mount --bind /etc/resolv.conf "${rootfs}/etc/resolv.conf"
    fi

    # Verify chroot works
    if ! chroot "${rootfs}" /bin/bash -c "uname -m" 2>/dev/null | grep -q aarch64; then
        echo "ERROR: aarch64 chroot failed" >&2
        exit 1
    fi

    echo "✓ Chroot ready (host: ${HOST_ARCH})"
}

teardown_chroot() {
    local rootfs="${ROOTFS_DIR}"

    # Restore systemctl
    [ -f "${rootfs}/bin/systemctl.orig" ] && \
        mv "${rootfs}/bin/systemctl.orig" "${rootfs}/bin/systemctl" 2>/dev/null || true

    # Restore mandb (requires chroot execution to be available)
    if [ "${QEMU_COPIED}" = "true" ] || [ "${HOST_ARCH}" = "aarch64" ]; then
        rm -f "${rootfs}/usr/bin/mandb" 2>/dev/null || true
        chroot "${rootfs}" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            dpkg-divert --rename --remove /usr/bin/mandb 2>/dev/null || true
    fi

    # Unmount (reverse order)
    for mnt in etc/resolv.conf tmp run sys proc dev/pts dev; do
        umount "${rootfs}/${mnt}" 2>/dev/null || true
    done

    # Remove injected files
    [ "${QEMU_COPIED}" = "true" ] && rm -f "${rootfs}/usr/bin/qemu-aarch64-static" 2>/dev/null || true
    rm -f "${rootfs}/usr/sbin/policy-rc.d" 2>/dev/null || true

    echo "✓ Chroot cleaned up"
}

# Run a script inside the ARM64 chroot
run_in_chroot() {
    chroot "${ROOTFS_DIR}" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive \
        DEFAULT_USERNAME="${DEFAULT_USERNAME}" \
        LC_ALL=C LANGUAGE=C \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash -c "$1"
}

# Register qemu-i386 binfmt for running NVIDIA flash tools on aarch64 hosts
setup_x86_binfmt() {
    # Mount binfmt_misc if not already mounted
    if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
        echo "Mounting binfmt_misc..."
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    fi

    if [ ! -w /proc/sys/fs/binfmt_misc/register ]; then
        echo "⚠ binfmt_misc not writable — flash tools may fail on aarch64" >&2
        return
    fi

    # Unregister stale entry if present
    [ -e /proc/sys/fs/binfmt_misc/qemu-i386 ] && \
        echo -1 > /proc/sys/fs/binfmt_misc/qemu-i386

    # ELF magic + mask for i386 (32-bit x86) binaries — matches NVIDIA flash tool ELFs
    printf '%s' \
        ':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:' \
        '\xff\xff\xff\xff\xff\xfe\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:' \
        '/usr/bin/qemu-i386-static:' \
        > /proc/sys/fs/binfmt_misc/register

    # Disable USB autosuspend — critical for flash reliability on aarch64 hosts
    if [ -w /sys/module/usbcore/parameters/autosuspend ]; then
        if echo -1 > /sys/module/usbcore/parameters/autosuspend; then
            echo "✓ USB autosuspend disabled ($(cat /sys/module/usbcore/parameters/autosuspend))"
        else
            echo "⚠ Could not disable USB autosuspend — continuing"
        fi
    else
        echo "⚠ Could not disable USB autosuspend — continuing"
    fi

    echo "✓ i386 binfmt registered (aarch64 host → NVIDIA flash tools)"
}

# ────────────────────────────────────────────────────
#  Phase 1: Host Dependencies
# ────────────────────────────────────────────────────

echo "── Phase 1: Host Dependencies ──"

REQUIRED_PKGS=(
    qemu-user-static binfmt-support wget tar lbzip2 usbutils
    device-tree-compiler abootimg dosfstools parted uuid-runtime
    python3 libxml2-utils xmlstarlet sshpass
)

# Detect WSL and add USB passthrough tools
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    echo "✓ WSL detected"
    REQUIRED_PKGS+=(linux-tools-generic hwdata)
fi

if [ "${HOST_ARCH}" = "aarch64" ]; then
    # On aarch64 hosts: need qemu-i386-static to run NVIDIA flash tools (i386 ELFs)
    # binfmt-support not required — we register manually via setup_x86_binfmt()
    REQUIRED_PKGS+=(qemu-user-static)
fi

MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "${pkg}" &>/dev/null || MISSING+=("${pkg}")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Installing: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y -qq "${MISSING[@]}"
    update-binfmts --enable qemu-aarch64 2>/dev/null || true
fi

# WSL: Symlink usbip tools to WSL kernel version
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    KERNEL_VER="$(uname -r)"
    TOOLS_DIR="/usr/lib/linux-tools"
    
    # Find the generic tools directory
    GENERIC_DIR="$(find ${TOOLS_DIR} -maxdepth 1 -type d -name '*-generic' | head -1)"
    
    if [ -n "${GENERIC_DIR}" ] && [ ! -d "${TOOLS_DIR}/${KERNEL_VER}" ]; then
        echo "Linking usbip tools for WSL kernel ${KERNEL_VER}..."
        ln -sf "${GENERIC_DIR}" "${TOOLS_DIR}/${KERNEL_VER}"
        echo "✓ usbip tools configured"
    fi
fi

echo "✓ Dependencies OK"
echo ""

# ────────────────────────────────────────────────────
#  Phase 2: Download
# ────────────────────────────────────────────────────

echo "── Phase 2: Download ──"
mkdir -p "${DOWNLOAD_DIR}"

BSP_TAR="${DOWNLOAD_DIR}/bsp.tbz2"
ROOTFS_TAR="${DOWNLOAD_DIR}/rootfs.tbz2"

[ -f "${BSP_TAR}" ]    && echo "⏭ BSP cached"    || { echo "Downloading BSP...";    wget -q --show-progress -O "${BSP_TAR}" "${BSP_URL}"; }
[ -f "${ROOTFS_TAR}" ] && echo "⏭ Rootfs cached" || { echo "Downloading rootfs..."; wget -q --show-progress -O "${ROOTFS_TAR}" "${ROOTFS_URL}"; }
echo "✓ Downloads OK"
echo ""

# ────────────────────────────────────────────────────
#  Phase 3: Extract
# ────────────────────────────────────────────────────

echo "── Phase 3: Extract ──"

if [ ! -f "${WORK_DIR}/flash.sh" ]; then
    echo "Extracting BSP..."
    mkdir -p "${WORKSPACE_DIR}/workdir"
    tar --no-same-owner -xjf "${BSP_TAR}" -C "${WORKSPACE_DIR}/workdir"
else
    echo "⏭ BSP extracted"
fi

if [ ! -f "${ROOTFS_DIR}/bin/bash" ]; then
    echo "Extracting rootfs..."
    mkdir -p "${ROOTFS_DIR}"
    tar --no-same-owner -xjf "${ROOTFS_TAR}" -C "${ROOTFS_DIR}"
else
    echo "⏭ Rootfs extracted"
fi
echo ""

# ────────────────────────────────────────────────────
#  Phase 4: Apply NVIDIA BSP Binaries
# ────────────────────────────────────────────────────

echo "── Phase 4: NVIDIA BSP Binaries ──"
mkdir -p "${STAMP_DIR}"

if [ ! -f "${STAMP_DIR}/nvidia-bsp" ]; then
    echo "Applying NVIDIA binaries..."
    pushd "${WORK_DIR}" > /dev/null
    ./apply_binaries.sh
    popd > /dev/null
    echo "applied" > "${STAMP_DIR}/nvidia-bsp"
    echo "✓ BSP binaries applied"
else
    echo "⏭ BSP binaries already applied"
fi

if [ ! -f "${STAMP_DIR}/default-user" ]; then
    echo "Creating user '${DEFAULT_USERNAME}'..."
    pushd "${WORK_DIR}" > /dev/null
    ./tools/l4t_create_default_user.sh \
        -u "${DEFAULT_USERNAME}" -p "${DEFAULT_PASSWORD}" -a --accept-license
    popd > /dev/null
    echo "applied" > "${STAMP_DIR}/default-user"
    echo "✓ User created"
else
    echo "⏭ User already created"
fi
echo ""

# ────────────────────────────────────────────────────
#  Phase 5: Customize Rootfs
# ────────────────────────────────────────────────────
#  Enters an ARM64 chroot and runs each script in
#  scripts/ in sorted order. On x86_64 hosts, QEMU
#  provides ARM64 emulation; on aarch64 hosts the
#  chroot runs natively with no emulation overhead.
#  Stamps track which scripts have been applied —
#  unchanged scripts are skipped, changed scripts are
#  re-applied. On failure, fix the script and re-run;
#  stamped scripts are skipped.
#  For a clean slate: sudo ./flash.sh --clean
# ────────────────────────────────────────────────────

echo "── Phase 5: Customize Rootfs ──"

SCRIPT_DIRS=()
if [ -d "${SCRIPTS_DIR}" ]; then
    while IFS= read -r d; do
        SCRIPT_DIRS+=("$d")
    done < <(find "${SCRIPTS_DIR}" -maxdepth 1 -type d -name "*-*" 2>/dev/null | sort)
fi

if [ ${#SCRIPT_DIRS[@]} -eq 0 ]; then
    echo "No scripts found, skipping."
else
    echo "Found ${#SCRIPT_DIRS[@]} script(s)"

    APPLIED=()
    SKIPPED=()

    trap teardown_chroot EXIT
    setup_chroot "${ROOTFS_DIR}"

    for script_dir in "${SCRIPT_DIRS[@]}"; do
        name="$(basename "${script_dir}")"

        [ ! -f "${script_dir}/run.sh" ] && { echo "⚠ ${name}: no run.sh"; continue; }

        # Content hash for idempotency
        hash="$(find "${script_dir}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
        stamp="${STAMP_DIR}/${name}"

        if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${hash}" ]; then
            echo "⏭ ${name}"
            SKIPPED+=("${name}")
            continue
        fi

        [ -f "${stamp}" ] && echo "⟳ ${name} (changed)" || echo "→ ${name}"

        rm -rf "${ROOTFS_DIR}/tmp/${name}"
        cp -r "${script_dir}" "${ROOTFS_DIR}/tmp/"
        chmod +x "${ROOTFS_DIR}/tmp/${name}/run.sh"

        if run_in_chroot "cd /tmp/${name} && bash run.sh"; then
            echo "✓ ${name}"
            echo "${hash}" > "${stamp}"
            APPLIED+=("${name}")
        else
            echo "✗ ${name} failed — fix and re-run (stamped scripts will be skipped)" >&2
            exit 1
        fi

        rm -rf "${ROOTFS_DIR}/tmp/${name}"
    done

    teardown_chroot
    trap - EXIT

    # Write manifest
    {
        echo "# Arche Environment — Build Manifest"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "git_commit=$(git -C "${WORKSPACE_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "l4t=${L4T_VERSION}  jetpack=${JETPACK_VERSION}  board=${BOARD}"
        echo "user=${DEFAULT_USERNAME}"
        for s in "${APPLIED[@]}";  do echo "applied=${s}"; done
        for s in "${SKIPPED[@]}";  do echo "skipped=${s}"; done
    } > "${BUILD_MANIFEST}"
    echo "✓ Manifest written"
fi
echo ""

# ────────────────────────────────────────────────────
#  Phase 6: Flash
# ────────────────────────────────────────────────────

echo "── Phase 6: Flash ──"

NVIDIA_USB="$(lsusb 2>/dev/null | grep -i '0955:' || true)"

if [ -n "${NVIDIA_USB}" ]; then
    echo "✓ Device detected: ${NVIDIA_USB}"
else
    echo "⚠  No NVIDIA device detected in USB recovery mode."
    echo ""
    echo "   To enter recovery mode:"
    echo "     1. Power off the Jetson"
    echo "     2. Hold RECOVERY (or jumper FC REC pins 9-10)"
    echo "     3. Apply power"
    echo "     4. Release RECOVERY after 2 seconds"
    echo "     5. Connect USB-C to this host"
    echo ""
    echo "   Proceeding anyway — the flash command may still work"
    echo "   if flashing to an external device or using --no-flash."
    echo ""
fi

echo ""
echo "Flashing... (do not disconnect)"
echo ""

if [ "${HOST_ARCH}" = "aarch64" ]; then
    setup_x86_binfmt
fi

cd "${WORK_DIR}"
eval "${FLASH_CMD}"

echo ""
echo "=========================================="
echo "  Done."
echo "=========================================="
echo "  Login: ${DEFAULT_USERNAME} / ${DEFAULT_PASSWORD}"
echo ""
