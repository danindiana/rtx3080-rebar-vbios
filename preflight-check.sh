#!/usr/bin/env bash
# preflight-check.sh
# Verifies all prerequisites are in place before you run vbios-preflight.sh.
# Safe to run at any time — read-only, no changes made.

WORK_DIR="$(dirname "$(realpath "$0")")"
PASS=0
FAIL=0

ok()   { echo "  [OK]  $*"; ((PASS++)) || true; }
miss() { echo "  [!!]  $*"; ((FAIL++)) || true; }
info() { echo "        $*"; }

echo "=========================================="
echo " ReBAR Flash Prerequisites Check"
echo " $(date)"
echo "=========================================="

echo ""
echo "-- Tools --"

if [ -f "$WORK_DIR/nvflash" ] && [ -x "$WORK_DIR/nvflash" ]; then
    VER=$("$WORK_DIR/nvflash" --version 2>/dev/null | head -1 || echo "unknown")
    ok "nvflash present and executable  ($VER)"
else
    miss "nvflash NOT found at $WORK_DIR/nvflash"
    info "Download from: https://www.techpowerup.com/download/nvidia-nvflash/"
    info "Extract the zip; copy the 'nvflash' binary here."
fi

if command -v 7z &>/dev/null; then
    ok "7z (p7zip-full) installed"
else
    miss "7z not found — install with: sudo apt install p7zip-full"
fi

echo ""
echo "-- VBIOS ROM --"

ROM_COUNT=$(find "$WORK_DIR" -maxdepth 1 -name "*.rom" ! -name "backup_*" | wc -l)
BACKUP_COUNT=$(find "$WORK_DIR" -maxdepth 1 -name "backup_3080_*.rom" | wc -l)

if [ "$ROM_COUNT" -gt 0 ]; then
    ROM_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "*.rom" ! -name "backup_*" | head -1)
    ROM_SIZE=$(wc -c < "$ROM_FILE")
    SHA=$(sha256sum "$ROM_FILE" | cut -d' ' -f1)
    ok "Target ROM found: $(basename "$ROM_FILE")  (${ROM_SIZE} bytes)"
    info "SHA256: $SHA"
    if [ "$ROM_SIZE" -lt 524288 ]; then
        miss "ROM is suspiciously small (< 512 KB) — verify it's the correct file"
    fi
else
    miss "No target ROM (.rom file) found in $WORK_DIR"
    info "Download ASUS TUF-RTX3080-10G-GAMING ReBAR VBIOS:"
    info "  1. Go to: https://www.asus.com/support/download-center/"
    info "  2. Search: TUF-RTX3080-10G-GAMING"
    info "  3. Firmware & Tools → 'Resizable BAR Firmware Update' or latest VBIOS"
    info "  4. Extract the .exe with: 7z x <filename>.exe -oasus_extracted"
    info "  5. Find the .rom file in asus_extracted/ and copy it here"
    info ""
    info "Alternative: https://www.techpowerup.com/vgabios/?did=10de-2206&subdid=1043-87b0"
    info "  (filter for 'ReBAR' in the version/notes column)"
fi

if [ "$BACKUP_COUNT" -gt 0 ]; then
    ok "Backup ROM already present (preflight was run previously)"
fi

echo ""
echo "-- System State --"

if [ -d /sys/firmware/efi ]; then
    ok "UEFI boot mode confirmed"
else
    miss "Legacy/BIOS boot mode — ReBAR will not work; disable CSM in BIOS"
fi

BAR1_3080=$(nvidia-smi -q --id=1 2>/dev/null \
    | awk '/BAR1 Memory Usage/{found=1} found && /Total/{print $(NF-1); exit}')
BAR1_3080_UNIT=$(nvidia-smi -q --id=1 2>/dev/null \
    | awk '/BAR1 Memory Usage/{found=1} found && /Total/{print $NF; exit}')

if [ "${BAR1_3080}" = "10240" ]; then
    ok "RTX 3080 BAR1 = 10240 MiB — ReBAR ALREADY ACTIVE (no flash needed!)"
elif [ -n "${BAR1_3080}" ]; then
    info "RTX 3080 BAR1 = ${BAR1_3080} ${BAR1_3080_UNIT}  (target: 10240 MiB — flash needed)"
fi

REBAR_BIOS=$(sudo lspci -vv -s 0f:00.0 2>/dev/null \
    | awk '/Physical Resizable BAR/{found=1} found && /BAR 1:/{print; exit}')
if echo "$REBAR_BIOS" | grep -q "10240"; then
    ok "BIOS already advertising 10240 MiB in ReBAR capability register"
elif [ -n "$REBAR_BIOS" ]; then
    info "PCIe ReBAR BAR1 register: $REBAR_BIOS"
    info "If 10240 MiB is not listed here, Phase 1 BIOS settings may still be needed"
fi

# BIOS settings inference: if 5080 has full BAR, motherboard is already configured
BAR1_5080=$(nvidia-smi -q --id=0 2>/dev/null \
    | awk '/BAR1 Memory Usage/{found=1} found && /Total/{print $(NF-1); exit}')
if [ "${BAR1_5080}" = "16384" ]; then
    ok "RTX 5080 BAR1 = 16384 MiB → Above-4G-Decoding + CSM-disabled already set in BIOS ✓"
fi

echo ""
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
    echo " STATUS: READY — all prerequisites met"
    echo ""
    echo " Next: Switch to TTY (Ctrl+Alt+F2) and run:"
    echo "   sudo bash $WORK_DIR/vbios-preflight.sh"
else
    echo " STATUS: NOT READY — $FAIL item(s) need attention (see above)"
fi
echo "=========================================="
