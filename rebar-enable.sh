#!/bin/bash
# Flash ReBAR-enabled VBIOS onto RTX 3080 (GPU index 1)
# gpumode approach failed on GA102 (0x2206); direct ROM flash required.
# Usage: sudo ~/vbios-work/rebar-enable.sh [rom_file]
#   Default ROM: 94.02.42.40.AS02.rom (same version, ReBAR-capable)
#   Alt ROM:     94.02.42.40.AS03.rom (same version, newer stepping)

NVFLASH=/home/jeb/vbios-work/x64/nvflash
WORKDIR=/home/jeb/vbios-work
BACKUP=$WORKDIR/3080-backup-pre-rebar.rom
LOG=$WORKDIR/flash-session.log
GPU_IDX=1

ROM="${1:-$WORKDIR/v6-extracted/94.02.42.40.AS02.rom}"

exec > >(tee -a "$LOG") 2>&1
echo ""
echo "========================================================"
echo "  RTX 3080 ReBAR Flash — $(date)"
echo "  ROM: $ROM"
echo "========================================================"

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

if [ ! -x "$NVFLASH" ]; then
    echo "ERROR: nvflash not found at $NVFLASH"
    exit 1
fi

if [ ! -f "$ROM" ]; then
    echo "ERROR: ROM file not found: $ROM"
    echo "Available ROMs:"
    ls -lh $WORKDIR/*.rom
    exit 1
fi

# ---------------------------------------------------------------------------
# [0] Stop all GPU consumers
# ---------------------------------------------------------------------------
echo "[0] Stopping GPU consumers..."
systemctl stop ollama 2>/dev/null \
    && echo "    Ollama: stopped" \
    || echo "    Ollama: not running"

# gpu-watchdog has Restart=always; systemctl stop bypasses the restart policy.
systemctl stop gpu-watchdog 2>/dev/null
sleep 1
pkill -9 -f "gpu_thermal.watchdog" 2>/dev/null || true
sleep 1
WD_STATE=$(systemctl show -p ActiveState --value gpu-watchdog 2>/dev/null)
WD_PID=$(systemctl show -p MainPID --value gpu-watchdog 2>/dev/null)
if [ "$WD_STATE" != "inactive" ] || [ "$WD_PID" != "0" ]; then
    echo "    gpu-watchdog: WARNING — state=$WD_STATE PID=$WD_PID, forcing..."
    systemctl kill --signal=SIGKILL gpu-watchdog 2>/dev/null || true
    pkill -9 -f "gpu_thermal.watchdog" 2>/dev/null || true
    sleep 2
fi
echo "    gpu-watchdog: stopped (state=$(systemctl show -p ActiveState --value gpu-watchdog))"

# nvidia-persistenced: mask first (static unit), then stop
systemctl mask nvidia-persistenced 2>/dev/null
systemctl stop nvidia-persistenced 2>/dev/null \
    && echo "    nvidia-persistenced: masked+stopped" \
    || echo "    nvidia-persistenced: masked (was not running)"
sleep 2

if fuser /dev/nvidia* >/dev/null 2>&1; then
    echo "    Killing remaining GPU processes..."
    fuser -k /dev/nvidia* 2>/dev/null
fi

WAITED=0
while fuser /dev/nvidia* >/dev/null 2>&1; do
    if [ $WAITED -ge 30 ]; then
        echo "ERROR: GPU processes still alive after 30s — aborting"
        lsof /dev/nvidia* 2>/dev/null | head -10
        systemctl unmask nvidia-persistenced 2>/dev/null
        systemctl start nvidia-persistenced gpu-watchdog 2>/dev/null
        exit 1
    fi
    echo "    Waiting for GPU handles to release... (${WAITED}s)"
    sleep 2
    WAITED=$((WAITED + 2))
done
echo "    All GPU handles released"

# ---------------------------------------------------------------------------
# [1] Stop X session
# ---------------------------------------------------------------------------
echo "[1] Stopping LightDM (X session will end)..."
systemctl stop lightdm
sleep 4

# ---------------------------------------------------------------------------
# [2] Unload NVIDIA kernel modules
# ---------------------------------------------------------------------------
echo "[2] Unloading NVIDIA kernel modules..."
modprobe -r nvidia_uvm 2>/dev/null
modprobe -r nvidia_drm 2>/dev/null
modprobe -r nvidia_modeset 2>/dev/null
modprobe -r nvidia 2>/dev/null
sleep 2

if lsmod | grep -q "^nvidia"; then
    echo "ERROR: NVIDIA modules still loaded — aborting"
    lsof /dev/nvidia* 2>/dev/null | head -20
    modprobe nvidia && modprobe nvidia_modeset && modprobe nvidia_drm && modprobe nvidia_uvm
    systemctl unmask nvidia-persistenced 2>/dev/null
    systemctl start nvidia-persistenced gpu-watchdog 2>/dev/null
    systemctl start lightdm
    exit 1
fi
echo "    Modules unloaded OK"

# ---------------------------------------------------------------------------
# [3] Verify GPU visible to nvflash
# ---------------------------------------------------------------------------
echo "[3] Verifying GPU is visible (nvflash --list)..."
$NVFLASH --list
LIST_STATUS=$?
if [ $LIST_STATUS -ne 0 ]; then
    echo "ERROR: nvflash --list failed (status $LIST_STATUS) — aborting"
    modprobe nvidia && modprobe nvidia_modeset && modprobe nvidia_drm && modprobe nvidia_uvm
    systemctl unmask nvidia-persistenced 2>/dev/null
    systemctl start nvidia-persistenced gpu-watchdog 2>/dev/null
    systemctl start lightdm
    exit 1
fi

# ---------------------------------------------------------------------------
# [4] Back up current VBIOS (skip if backup already exists and is valid)
# ---------------------------------------------------------------------------
echo "[4] Backing up current VBIOS (GPU $GPU_IDX)..."
if [ -s "$BACKUP" ]; then
    echo "    Existing backup found: $BACKUP ($(stat -c%s "$BACKUP") bytes) — skipping re-backup"
else
    $NVFLASH -i $GPU_IDX --save "$BACKUP"
    BACKUP_STATUS=$?
    if [ $BACKUP_STATUS -ne 0 ] || [ ! -s "$BACKUP" ]; then
        echo "ERROR: Backup failed (status $BACKUP_STATUS) — aborting (no backup = no flash)"
        modprobe nvidia && modprobe nvidia_modeset && modprobe nvidia_drm && modprobe nvidia_uvm
        systemctl unmask nvidia-persistenced 2>/dev/null
        systemctl start nvidia-persistenced gpu-watchdog 2>/dev/null
        systemctl start lightdm
        exit 1
    fi
    echo "    Backup OK: $BACKUP ($(stat -c%s "$BACKUP") bytes)"
fi

# ---------------------------------------------------------------------------
# [5] Check ROM compatibility
# ---------------------------------------------------------------------------
echo "[5] Checking ROM compatibility..."
echo "    ROM size: $(stat -c%s "$ROM") bytes"
# Capture output to surface any mismatch; we proceed to the flash step either way.
CHECK_OUT=$($NVFLASH -i $GPU_IDX --check "$ROM" 2>&1)
CHECK_STATUS=$?
echo "$CHECK_OUT"
echo "    check exit status: $CHECK_STATUS"

# ---------------------------------------------------------------------------
# [6] Flash ROM — nvflash 5.867 Linux: NO force flags exist. Pass only the
#     ROM filename; nvflash checks subsystem ID and prompts y/n if it matches.
#     AS02 subsystem (1043:87B0) matches the card so no override is needed.
#     --force-subsystem-id/--force-board-id are Windows-only flags.
#     --forcesub/--forceboard also cause "Command format not recognized".
#     nvflash opens /dev/console directly; use expect to drive the TTY.
# ---------------------------------------------------------------------------
echo "[5b] Removing firmware write-protect (--protectoff)..."
expect -c "
    set timeout 30
    spawn $NVFLASH -i $GPU_IDX --protectoff
    expect {
        -re {[Yy]/[Nn]}  { send \"y\r\"; exp_continue }
        -re {Press.*Enter} { send \"\r\"; exp_continue }
        timeout           { exit 3 }
        eof
    }
    catch wait result
    exit [lindex \$result 3]
" 2>&1
PROTECTOFF_STATUS=$?
echo "    protectoff exit status: $PROTECTOFF_STATUS (non-zero may be OK if no protect was set)"

echo "[6] Flashing ROM to GPU $GPU_IDX..."
echo "    *** Do NOT interrupt — takes ~30 seconds ***"
expect -c "
    set timeout 120
    spawn $NVFLASH -i $GPU_IDX {$ROM}
    expect {
        -re {[Yy]/[Nn]}  { send \"y\r\"; exp_continue }
        -re {Press.*Enter} { send \"\r\"; exp_continue }
        -re {confirm}     { send \"y\r\"; exp_continue }
        timeout           { exit 3 }
        eof
    }
    catch wait result
    exit [lindex \$result 3]
"
FLASH_STATUS=$?
echo "    Flash exit status: $FLASH_STATUS"

# ---------------------------------------------------------------------------
# [7] Quick read-back to confirm flash completed
# ---------------------------------------------------------------------------
echo "[7] Read-back verification..."
VERIFY_ROM=/tmp/post-flash-verify-$$.rom
$NVFLASH -i $GPU_IDX --save "$VERIFY_ROM" 2>/dev/null
if [ -s "$VERIFY_ROM" ]; then
    echo "    Post-flash read OK ($(stat -c%s "$VERIFY_ROM") bytes)"
    rm -f "$VERIFY_ROM"
else
    echo "    WARNING: Post-flash read returned empty/no file"
fi

# ---------------------------------------------------------------------------
# [8] Reload NVIDIA kernel modules
# ---------------------------------------------------------------------------
echo "[8] Reloading NVIDIA kernel modules..."
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
modprobe nvidia_uvm
sleep 2

# ---------------------------------------------------------------------------
# [9] Restore services
# ---------------------------------------------------------------------------
echo "[9] Restoring services..."
systemctl unmask nvidia-persistenced 2>/dev/null
systemctl start nvidia-persistenced gpu-watchdog 2>/dev/null
echo "    nvidia-persistenced + gpu-watchdog started"

# ---------------------------------------------------------------------------
# [10] Restart X
# ---------------------------------------------------------------------------
echo "[10] Restarting LightDM..."
systemctl start lightdm
sleep 3

# ---------------------------------------------------------------------------
# [11] Result
# ---------------------------------------------------------------------------
echo "[11] Done."
if [ $FLASH_STATUS -eq 0 ]; then
    echo "SUCCESS: ROM flashed."
    echo "REBOOT REQUIRED — BAR1 change takes effect after reboot."
    echo "After reboot verify: nvidia-smi -q -i 1 | grep -A3 'BAR1'"
    echo "Expected: Total = 8192 MiB (8 GiB)"
    echo ""
    echo "To restore original VBIOS if needed:"
    echo "  sudo $NVFLASH -i $GPU_IDX $BACKUP"
else
    echo "FAILED: nvflash exited with status $FLASH_STATUS — VBIOS was NOT changed."
    echo "Backup is safe at: $BACKUP"
    echo ""
    echo "Possible causes:"
    echo "  - ROM subsystem mismatch (try AS03.rom as alternative)"
    echo "  - nvflash version incompatible with this VBIOS"
    echo "  - Hardware write-protect enabled (check GPU dipswitch)"
fi
echo "========================================================"
echo "  End $(date)"
echo "========================================================"
