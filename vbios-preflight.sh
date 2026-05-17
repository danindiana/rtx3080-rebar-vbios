#!/usr/bin/env bash
# vbios-preflight.sh
# Prepares worlock for RTX 3080 VBIOS flash.
# Run as root from a TTY (Ctrl+Alt+F2), NOT from inside an X session.
# The display manager kill will drop your graphical session.
set -euo pipefail

RTX3080_PCI="0f:00.0"
BACKUP_FILE="backup_3080_$(date +%Y%m%d_%H%M%S).rom"
WORK_DIR="$(dirname "$(realpath "$0")")"

echo "======================================================"
echo " RTX 3080 VBIOS Preflight — worlock"
echo " $(date)"
echo "======================================================"

# ------------------------------------------------------------------
# 1. Confirm UEFI boot mode (ReBAR requires UEFI; CSM must be OFF)
# ------------------------------------------------------------------
echo ""
echo "[1/6] Checking boot mode..."
if [ ! -d /sys/firmware/efi ]; then
    echo "FATAL: System booted in Legacy/BIOS mode." >&2
    echo "       Disable CSM in the X570 Taichi BIOS and reboot." >&2
    exit 1
fi
echo "      UEFI confirmed ✓"

# ------------------------------------------------------------------
# 2. Show current BAR state for both GPUs
# ------------------------------------------------------------------
echo ""
echo "[2/6] Current BAR1 state (both GPUs):"
nvidia-smi -q | grep -i "bar1" -A 3 || echo "      (nvidia-smi unavailable — drivers may already be unloaded)"

echo ""
echo "      PCIe ReBAR capability on RTX 3080 (${RTX3080_PCI}):"
lspci -vv -s "${RTX3080_PCI}" 2>/dev/null \
    | grep -iE "resizable|prefetchable|size=" \
    | head -6 \
    || echo "      (lspci data unavailable)"

# ------------------------------------------------------------------
# 3. Stop Ollama inference service
# ------------------------------------------------------------------
echo ""
echo "[3/6] Stopping Ollama service..."
if systemctl is-active --quiet ollama 2>/dev/null; then
    systemctl stop ollama
    echo "      Ollama stopped ✓"
else
    echo "      Ollama was not running"
fi

# ------------------------------------------------------------------
# 4. Stop display manager (this will kill your X session if running)
# ------------------------------------------------------------------
echo ""
echo "[4/6] Stopping display manager..."
DM_STOPPED=""
for DM in lightdm gdm gdm3 sddm; do
    if systemctl is-active --quiet "$DM" 2>/dev/null; then
        echo "      Stopping $DM..."
        systemctl stop "$DM"
        DM_STOPPED="$DM"
        break
    fi
done
if [ -z "$DM_STOPPED" ]; then
    echo "      No active display manager found"
fi
# Give X time to fully die
sleep 2

# Kill any remaining X processes just in case
pkill -x Xorg 2>/dev/null || true
pkill -x X     2>/dev/null || true
sleep 1
echo "      Display manager stopped ✓"

# ------------------------------------------------------------------
# 5. Unload NVIDIA kernel modules in correct dependency order
# ------------------------------------------------------------------
echo ""
echo "[5/6] Unloading NVIDIA kernel modules..."
MODULES=(nvidia_uvm nvidia_drm nvidia_modeset nvidia)
for mod in "${MODULES[@]}"; do
    if lsmod | grep -q "^${mod} "; then
        echo "      Removing $mod..."
        modprobe -r "$mod" || {
            echo "WARN: Could not remove $mod — something may still hold it." >&2
            echo "      Check: lsof /dev/nvidia* and kill blocking processes." >&2
        }
    else
        echo "      $mod not loaded, skipping"
    fi
done
echo "      Module unload complete ✓"

# ------------------------------------------------------------------
# 6. Backup current VBIOS of GPU index 1 (the RTX 3080)
# ------------------------------------------------------------------
echo ""
echo "[6/6] Backing up current RTX 3080 VBIOS..."
if [ ! -f "${WORK_DIR}/nvflash" ]; then
    echo "FATAL: nvflash not found at ${WORK_DIR}/nvflash" >&2
    echo "       Download from https://www.techpowerup.com/download/nvidia-nvflash/" >&2
    exit 1
fi

"${WORK_DIR}/nvflash" --save "${WORK_DIR}/${BACKUP_FILE}" --index 1
echo "      Backup saved: ${WORK_DIR}/${BACKUP_FILE}"
sha256sum "${WORK_DIR}/${BACKUP_FILE}" | tee "${WORK_DIR}/${BACKUP_FILE}.sha256"
echo "      SHA256 recorded ✓"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "======================================================"
echo " Preflight complete. Safe to flash."
echo ""
echo " Backup: ${WORK_DIR}/${BACKUP_FILE}"
echo ""
echo " Flash command:"
echo "   sudo ${WORK_DIR}/nvflash -6 --index 1 <your_rom_file.rom>"
echo ""
echo " Type YES (all caps) when prompted."
echo "======================================================"
