# RTX 3080 ReBAR / VBIOS Update — Implementation Guide
## System Context (worlock)

| Component | Detail |
|-----------|--------|
| OS | Xubuntu 22.04.5 LTS (kernel 6.8.12) |
| Motherboard | ASRock X570 Taichi |
| CPU | AMD Ryzen 9 5950X (32 threads) |
| RAM | 128 GB |
| GPU 0 | RTX 5080 — `00000000:0E:00.0` — 16 GB — ReBAR **ENABLED** ✅ |
| GPU 1 | RTX 3080 — `00000000:0F:00.0` — 10 GB — ReBAR **DISABLED** ❌ |
| Display | Connected to GPU 1 (RTX 3080, `Disp.A: On`) |
| Driver | 580.142 / CUDA 13.0 |
| Display Manager | LightDM (Xfce/Xubuntu default) |
| Inference Service | `ollama` — PID 530341 — active on both GPUs |

**Goal:** Enable Resizable BAR on the RTX 3080 so both GPUs present full VRAM windows over
PCIe Gen 4, removing the 256 MiB choke point that limits cross-GPU data throughput during
multi-GPU Ollama inference.

---

## Phase 1 — Motherboard BIOS (Try First, No Risk)

The X570 Taichi supports ReBAR but requires these toggles to be explicit.

1. Boot to BIOS (`Delete` key on POST).
2. Navigate to **Advanced → AMD CBS → NBIO Common Options → SMU Common Options**:
   - **Above 4G Decoding** → `Enabled`
   - **Re-Size BAR Support** → `Enabled` (may appear as "SAM" / Smart Access Memory)
3. Navigate to **Boot → CSM (Compatibility Support Module)**:
   - **CSM** → `Disabled` — ReBAR is a UEFI-only feature; CSM will silently break it.
4. Save & Exit (`F10`).

After reboot, verify before proceeding to Phase 2:

```bash
sudo lspci -vv -s 0f:00.0 2>/dev/null | grep -i "resizable\|prefetchable" | head -6
nvidia-smi -q | grep -i "bar1" -A 3
```

If BAR1 still shows `256 MiB`, proceed to Phase 2.

---

## Phase 2 — VBIOS Update via Linux

ASUS ships VBIOS updates as Windows `.exe` installers. We extract the ROM and flash it
directly using the Linux build of `nvflash`.

### 2.1 — Identify Your Exact 3080 Model

```bash
# Get subsystem ID to confirm TUF / Strix / FE variant
sudo lspci -vv -s 0f:00.0 | grep -i "subsystem"
# Also confirm current VBIOS version
nvidia-smi --query-gpu=vbios_version --format=csv,noheader --id=1
```

Current known VBIOS: `94.02.42.40.66` (ASUSTeK subsystem).
Cross-reference the subsystem ID at https://www.techpowerup.com/gpu-specs/ before
downloading any ROM — **TUF, Strix, and ROG variants have different ROMs and are not
interchangeable**.

### 2.2 — Download Tools

- **nvflash for Linux:** https://www.techpowerup.com/download/nvidia-nvflash/
- **ASUS VBIOS Tool:** https://www.asus.com/support/Download-Center/
  - Search your exact model (e.g., `TUF-RTX3080-10G-GAMING`)
  - Download the **Resizable BAR Firmware Update** package

```bash
mkdir -p ~/vbios-work && cd ~/vbios-work

# Download and extract nvflash
unzip nvflash_*.zip
chmod +x nvflash

# Install 7zip if needed
sudo apt install p7zip-full

# Extract the ASUS .exe to find the .rom
7z x RTX3080_*.exe -oasus_vbios_extracted
ls -lh asus_vbios_extracted/
# Look for a file ending in .rom — typically ~1–2 MB
```

### 2.3 — Checksum the ROM Before Flashing

```bash
# Record SHA256 of the extracted ROM before you do anything else
sha256sum asus_vbios_extracted/*.rom | tee rom_checksum.txt
cat rom_checksum.txt
```

Compare this against the checksum published on the ASUS support page or TechPowerUp's
VBIOS database. **Do not flash a ROM whose checksum you cannot verify.**

### 2.4 — Run the Preflight Script

```bash
sudo bash vbios-preflight.sh
```

This script (see `vbios-preflight.sh`):
- Confirms UEFI boot mode
- Shows current BAR1 state for both GPUs
- Stops `ollama`, LightDM, and unloads NVIDIA kernel modules in the correct order
- Backs up the current VBIOS to a timestamped `.rom` file

### 2.5 — Flash (CRITICAL)

> ⚠️ **Risk acknowledgment:** VBIOS flashing can brick the card. You have an RTX 5080 on
> the same system; if the 3080 becomes unbootable, you can recover by booting with only
> the 5080 installed and re-flashing via integrated graphics or the 5080. Keep
> `backup_3080_<date>.rom` somewhere safe (not just on this machine).

```bash
cd ~/vbios-work

# Target GPU index 1 explicitly (the 3080 is GPU 1 in nvidia-smi)
# -6 bypasses board ID check — required for ASUS custom-subsystem ROMs
# --index 1 ensures we flash the 3080, NOT the 5080
sudo ./nvflash -6 --index 1 your_extracted_file.rom
```

Type `YES` (case-sensitive, all caps) when prompted.

### 2.6 — Reboot and Verify

```bash
sudo reboot
# After reboot:
bash vbios-verify.sh
```

Expected output:
```
BAR1 Memory Usage
    Total                             : 10240 MiB   ← full 10 GB window
    Used                              : 0 MiB
    Free                              : 10240 MiB
```

---

## Phase 3 — Ollama Multi-GPU Tuning (Post-ReBAR)

Once ReBAR is confirmed active on the 3080, update your Ollama service environment to
make full use of both GPUs.

```bash
# /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="CUDA_VISIBLE_DEVICES=0,1"
Environment="OLLAMA_GPU_OVERHEAD=0"
# With ReBAR, the 3080's 10 GB is now fully addressable — increase max loaded models
Environment="OLLAMA_MAX_LOADED_MODELS=2"
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
# Verify both GPUs visible to ollama
nvidia-smi dmon -s u -d 2
```

---

## Recovery Plan

If the 3080 does not POST after flashing:

1. Power off; remove the 3080; boot on the 5080 alone.
2. The system will use the 5080 for display automatically.
3. Re-seat the 3080; boot; it should appear headless via PCIe.
4. Re-flash with the backup ROM:
   ```bash
   sudo ./nvflash -6 --index 1 backup_3080_<date>.rom
   ```
5. If `nvflash` cannot see the card, try adding `--bulldoze` flag (last resort).

---

## File Inventory (Claude Code Handoff)

| File | Purpose |
|------|---------|
| `REBAR_VBIOS_GUIDE.md` | This document |
| `vbios-preflight.sh` | Stop services, unload drivers, backup current VBIOS |
| `vbios-verify.sh` | Post-reboot confirmation of ReBAR state |

**Implementation order for Claude Code:**
1. Place all three files in `~/vbios-work/` on worlock.
2. Run `vbios-preflight.sh` as root from a TTY (not inside Xfce/alacritty — the display manager kill will drop your session).
3. Flash as described in §2.5.
4. Reboot; run `vbios-verify.sh`.
5. Apply Ollama override in §3 if verify passes.
