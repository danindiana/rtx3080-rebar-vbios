#!/usr/bin/env bash
# vbios-verify.sh
# Run after reboot to confirm ReBAR is active on the RTX 3080.
# No root required for most checks; sudo needed for lspci -vv.
set -euo pipefail

RTX3080_PCI="0f:00.0"
RTX5080_PCI="0e:00.0"
PASS=0
FAIL=0

pass() { echo "  ✓  $*"; ((PASS++)) || true; }
fail() { echo "  ✗  $*" >&2; ((FAIL++)) || true; }
info() { echo "  →  $*"; }

echo "======================================================"
echo " RTX 3080 ReBAR Verification — worlock"
echo " $(date)"
echo "======================================================"

# ------------------------------------------------------------------
# 1. UEFI boot mode
# ------------------------------------------------------------------
echo ""
echo "[1] Boot mode:"
if [ -d /sys/firmware/efi ]; then
    pass "UEFI mode confirmed"
else
    fail "Legacy/BIOS mode detected — ReBAR cannot work"
fi

# ------------------------------------------------------------------
# 2. VBIOS version (compare to pre-flash baseline 94.02.42.40.66)
# ------------------------------------------------------------------
echo ""
echo "[2] VBIOS versions:"
VBIOS_5080=$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader --id=0 2>/dev/null || echo "unavailable")
VBIOS_3080=$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader --id=1 2>/dev/null || echo "unavailable")
info "RTX 5080 VBIOS : ${VBIOS_5080}"
info "RTX 3080 VBIOS : ${VBIOS_3080}"
if [ "$VBIOS_3080" = "94.02.42.40.66" ]; then
    fail "RTX 3080 VBIOS unchanged from baseline — flash may not have applied"
else
    pass "RTX 3080 VBIOS updated to ${VBIOS_3080}"
fi

# ------------------------------------------------------------------
# 3. BAR1 window size — primary ReBAR indicator
# ------------------------------------------------------------------
echo ""
echo "[3] BAR1 memory windows:"
nvidia-smi -q | grep -i "bar1" -A 3

# Extract the Total BAR1 for GPU 1
BAR1_TOTAL=$(nvidia-smi -q --id=1 2>/dev/null \
    | awk '/BAR1 Memory Usage/{found=1} found && /Total/{print $NF; exit}')
BAR1_UNIT=$(nvidia-smi -q --id=1 2>/dev/null \
    | awk '/BAR1 Memory Usage/{found=1} found && /Total/{print $(NF-1); exit}')

echo ""
if [ "${BAR1_TOTAL}" = "10240" ] && [ "${BAR1_UNIT}" = "MiB" ]; then
    pass "RTX 3080 BAR1 = 10240 MiB — ReBAR ACTIVE ✓"
elif [ -n "${BAR1_TOTAL}" ]; then
    fail "RTX 3080 BAR1 = ${BAR1_TOTAL} ${BAR1_UNIT} — expected 10240 MiB"
    info "If this shows 256 MiB, revisit BIOS settings (Above 4G Decoding + CSM disabled)"
else
    fail "Could not parse BAR1 size — check nvidia-smi output above manually"
fi

# ------------------------------------------------------------------
# 4. PCIe capability register (hardware-level confirmation)
# ------------------------------------------------------------------
echo ""
echo "[4] PCIe ReBAR capability (hardware register):"
echo "    RTX 5080 (${RTX5080_PCI}):"
sudo lspci -vv -s "${RTX5080_PCI}" 2>/dev/null \
    | grep -iE "resizable|prefetchable|region [0-9]" \
    | sed 's/^/      /' \
    || info "  lspci data unavailable"

echo "    RTX 3080 (${RTX3080_PCI}):"
sudo lspci -vv -s "${RTX3080_PCI}" 2>/dev/null \
    | grep -iE "resizable|prefetchable|region [0-9]" \
    | sed 's/^/      /' \
    || info "  lspci data unavailable"

# ------------------------------------------------------------------
# 5. GPU inventory sanity check
# ------------------------------------------------------------------
echo ""
echo "[5] GPU inventory:"
nvidia-smi -L
# Confirm both GPUs are enumerated
GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -ge 2 ]; then
    pass "Both GPUs visible to driver (${GPU_COUNT} found)"
else
    fail "Expected 2 GPUs, found ${GPU_COUNT}"
fi

# ------------------------------------------------------------------
# 6. Ollama service status
# ------------------------------------------------------------------
echo ""
echo "[6] Ollama service:"
if systemctl is-active --quiet ollama 2>/dev/null; then
    pass "ollama.service is running"
else
    info "ollama.service is not running — start with: sudo systemctl start ollama"
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "======================================================"
if [ "${FAIL}" -eq 0 ]; then
    echo " RESULT: ALL CHECKS PASSED (${PASS}/${PASS})"
    echo ""
    echo " Next step: Apply Ollama multi-GPU override"
    echo "   sudo mkdir -p /etc/systemd/system/ollama.service.d/"
    echo "   sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'"
    echo "   [Service]"
    echo "   Environment=\"CUDA_VISIBLE_DEVICES=0,1\""
    echo "   Environment=\"OLLAMA_MAX_LOADED_MODELS=2\""
    echo "   EOF"
    echo "   sudo systemctl daemon-reload && sudo systemctl restart ollama"
else
    echo " RESULT: ${FAIL} check(s) FAILED — review output above"
    echo " Passed: ${PASS}  Failed: ${FAIL}"
fi
echo "======================================================"
