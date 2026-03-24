# Jetson Provisioner

Builds and flashes a customized NVIDIA Jetson Linux image from an x86 Ubuntu (or WSL) host.

```bash
sudo ./flash.sh
```

## How It Works

`flash.sh` runs a linear pipeline. Each phase checkpoints its work, so re-running after a failure picks up where it left off.

| Phase | Description |
|-------|-------------|
| 1 | Install host dependencies (QEMU, binfmt, etc.) |
| 2 | Download L4T BSP + sample rootfs |
| 3 | Extract into `workdir/` |
| 4 | Apply NVIDIA BSP binaries, create default user |
| 5 | Enter QEMU ARM64 chroot, run customization scripts |
| 6 | Detect device, flash |

### Failure recovery

Scripts are stamped with a SHA-256 content hash after each successful run. If `flash.sh` is interrupted or a script fails:

- Re-run `sudo ./flash.sh` — phases 1–4 are skipped (already done), and previously successful scripts in phase 5 are skipped (stamped).
- The failed script re-executes. Fix it and re-run.
- For a clean slate: `sudo ./flash.sh --clean`

### Device detection

Phase 6 checks for a Jetson in USB recovery mode via `lsusb`. If no device is found, it warns but proceeds — this allows use with `--no-flash` or external device flashing.

## Customization Scripts

Drop numbered directories into `scripts/`:

```
scripts/
├── 00-packages/
│   └── run.sh        # apt-get install your packages
└── 01-services/
    └── run.sh        # disable unneeded services
```

Each `run.sh` runs inside an ARM64 chroot. Scripts execute in sort order and must be **idempotent** — the stamp system skips unchanged scripts, and changed scripts are re-applied.

Available inside scripts: `DEFAULT_USERNAME`, `DEBIAN_FRONTEND=noninteractive`, full `apt` and `systemctl enable/disable`.

## Configuration

Edit [config.sh](config.sh) or override via environment:

```bash
BOARD=jetson-agx-orin-devkit sudo ./flash.sh
```

| Variable | Default |
|----------|---------|
| `BOARD` | `jetson-orin-nano-devkit` |
| `L4T_VERSION` | `36.3.0` |
| `DEFAULT_USERNAME` | `jetson` |
| `DEFAULT_PASSWORD` | `jetson` |
| `FLASH_CMD` | NVMe initrd flash |

## Prerequisites

- Ubuntu 22.04 (native or VM)
- 20GB+ free disk space
- USB to Jetson in recovery mode (for flash step)

Host packages are installed automatically.

### Note for WSL users

If editing files from Windows, ensure your editor uses Unix line endings (LF, not CRLF). If you see `$'\r': command not found`, run:

```bash
sed -i 's/\r$//' config.sh flash.sh scripts/*/run.sh
```
