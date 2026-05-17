# Lessons Learned — RTX 3080 ReBAR VBIOS Flash (worlock, May 2026)

This document captures the full project narrative, failure analysis, and takeaways from enabling Resizable BAR (ReBAR) on an RTX 3080 via VBIOS flash on a Linux dual-GPU workstation. It complements the operator reference in [README.md](README.md) and the step-by-step walkthrough in [REBAR_VBIOS_GUIDE.md](REBAR_VBIOS_GUIDE.md).

---

## 1. Project Background

The RTX 3080's factory VBIOS lacked the ReBAR capability bit. BAR1 was capped at 256 MiB, bottlenecking multi-GPU Ollama inference — the RTX 5080 in the same system had ReBAR natively (16 GB BAR1), confirming the system fully supported it. Fixing the 3080 required flashing a VBIOS from ASUS that includes the capability bits, then rebooting so UEFI could reassign the larger BAR.

The constraint: flash had to succeed on a live Linux system without a spare recovery machine. The RTX 5080 served as the safe display path and recovery anchor.

---

## 2. Timeline of Attempts (May 14–17, 2026)

| Session | Date | Outcome |
|---------|------|---------|
| 1 | May 14 | Strategy and script created. Flash never executed — waiting for confirmation. |
| 2 | May 17 ~09:56 | First attempt. Aborted at module unload. No backup created. |
| 3–7 | May 17 (various) | Repeated attempts with same failing pattern. Each session opened with "did the last one work?" — answer was no. |
| 8 | May 17 | Root cause of ALL silent failures identified: wrong nvflash flags. Script fixed. |
| 9 | May 17 | ROM target analysis completed. AS02 confirmed as correct target. |
| 10 | May 17 ~11:41 | Successful flash. ~40 seconds. Backup created. |
| 11 | May 17 (post-reboot) | Verified: BAR1 256 MiB → 16 GB. ✓ |

---

## 3. Root Cause Analysis of All Failures

### Failure 1 — Module Unload Blockage

**Symptom:** Script aborted at "unload NVIDIA modules" step after stopping LightDM.

**Root cause:** Simply stopping the display manager is insufficient. Multiple consumers held live GPU references:
- `ollama.service` — systemd service, active even when the GUI is down
- `nvidia-persistenced` — `Restart=always` means it restarts immediately after a `systemctl stop`
- `gpu-watchdog` — user-space process that also holds a handle; required `pkill -9`
- Docker containers with NVIDIA runtime (if running)

**Fix:** Explicit pre-flash teardown sequence: stop Ollama, mask and stop nvidia-persistenced, pkill gpu-watchdog, then attempt module unload. See `vbios-preflight.sh`.

---

### Failure 2 — Wrong nvflash Flags (Critical — caused ALL silent failures)

**Symptom:** Flash appeared to complete. VBIOS version changed unexpectedly (`.66` → `.65`). BAR1 still 256 MiB. No error message.

**Root cause:** The script used `--force-subsystem-id --force-board-id` — **Windows-only nvflash flags**. Linux nvflash 5.867 does not recognize them. Instead of erroring, it prints "Command format not recognized" and silently drops into **interactive mode**. The `expect` script was designed for a direct flash, not the interactive compatibility menu — it navigated the menus incorrectly, landing on AS03 (.65) instead of AS02 (.66).

**Diagnosis method:**
```bash
strings ~/vbios-work/x64/nvflash | grep force
# Output: --forcesub  --forceboard
# --force-subsystem-id and --force-board-id do NOT appear
```

**Fix:** Use `--forcesub --forceboard` in the nvflash invocation. This is the single change that unblocked everything.

**Why this is especially dangerous:** nvflash gives no warning that it ignored your flags and entered interactive mode. You only discover the failure by inspecting the resulting VBIOS version and BAR1 size post-reboot. A less careful operator might have assumed success.

---

### Failure 3 — ROM Target Confusion

**Symptom:** ASUS V6 package contains four ROM files. AS08 has the highest version string and was initially considered as the flash target.

**Root cause:** ASUS VBIOS version suffixes (`.66`, `.65`, `.80`) are **variant codes for PCB revisions**, not sequential upgrade numbers. AS08/AS09 have subsystem ID `1043:87EB` (TURBO RTX 3080 variant) — a different PCB. Cross-flashing would be dangerous.

**Diagnosis:**
- Read `BIOS_Compare.ini` in the ASUS package — it maps subsystem IDs to ROM variants
- Confirmed via TechPowerUp database: `1043:87B0` = TUF Gaming OC 10G; `1043:87EB` = TURBO
- AS02 (`.66`) and AS03 (`.65`) are the only valid ROMs for this board; AS02 is the newer build

**Fix:** Always match subsystem ID first, then pick the higher build number within the matching variants. Never sort by version string across variants.

---

### Failure 4 — Display Loss Risk

**Symptom:** Initial setup had monitors on the RTX 3080. Flashing would black out all outputs with no operator visibility.

**Fix:** Confirmed RTX 5080 as primary display adapter. Moved one monitor to the 5080 before any flash attempt. The 5080 stays untouched throughout the entire procedure and provides visibility even during kernel module unload on the 3080.

---

## 4. Key Decisions That Worked

**`expect` instead of `yes | nvflash`**
nvflash reads from `/dev/console`, not stdin. Piped `yes` is silently discarded. `expect` intercepts the actual TTY prompts and responds correctly. This is non-obvious and not documented in nvflash's help output.

**Mask `nvidia-persistenced`, don't just stop it**
`Restart=always` in the unit file means `systemctl stop nvidia-persistenced` is immediately undone by systemd. Masking (`systemctl mask`) prevents restart until explicitly unmasked.

**Dual-ROM strategy**
AS02 (`.66`) is the preferred target; AS03 (`.65`) is the documented fallback for the same `1043:87B0` PCB. Having a fallback avoids a dead end if the primary ROM is rejected.

**Timestamped backup with SHA256 before flash**
`3080-backup-pre-rebar.rom` was created and its hash recorded before the flash began. If the flash had failed mid-write, the recovery path was: remove the 3080, boot with only the 5080, re-flash from a second machine or USB stick.

**Script continues after X dies**
`rebar-enable.sh` was run in a root shell. When LightDM stopped and X terminated, the script continued — systemd's process context for the root shell is independent of the display session. This avoided the need for a VTY switch mid-flash.

---

## 5. Counterintuitive Discoveries

- **nvflash does NOT error on unrecognized flags** — it silently enters interactive mode. This is the most dangerous behavior in the toolchain. Test all flags on the target platform before automating.

- **ASUS version numbers are variant codes, not builds** — `.66` is not newer than `.65` across all variants; it is only newer within the same subsystem ID family.

- **`lspci` BAR1 "supported" sizes are VBIOS capability, not UEFI assignment** — a newly-capable VBIOS still requires `pci=realloc` kernel param and a full reboot for UEFI to assign the larger window. `nvidia-smi` BAR1 size can be misleading if checked before reboot.

- **nvflash `--help` is incomplete** — it does not list all valid flags. `strings` inspection of the binary is the reliable method for discovering what's actually supported.

- **nvflash exit code 5 means interactive compatibility check failure** — not a permissions error or file-not-found. Seeing exit 5 from inside an `expect` script means the interactive menu was reached and navigation failed.

- **`OLLAMA_MAX_LOADED_MODELS=2` is required for both GPUs to be used** — increasing BAR1 alone does not change model distribution. Ollama's service configuration must also permit multi-model loading.

---

## 6. Reproducibility Locks

For anyone repeating this procedure on similar hardware:

| Item | Value |
|------|-------|
| nvflash version | 5.867.0 Linux x64 |
| ASUS VBIOS package | V6, 2023-10-18 |
| Target ROM | `94.02.42.40.AS02.rom` |
| Target subsystem | `1043:87B0` (TUF Gaming RTX 3080 OC 10G) |
| Linux kernel | 6.8.12 |
| NVIDIA driver | 580.142 (CUDA 13.0) |
| Kernel param | `pci=realloc` in `GRUB_CMDLINE_LINUX_DEFAULT` |
| BIOS settings | Above 4G Decoding ON, Re-Size BAR Support ON, CSM OFF |

Deviating from the nvflash version carries unknown risk — the flag interface has changed across releases.

---

## 7. What Would Be Done Differently Next Time

1. **Verify all flags on the target platform first.** Run `strings <binary> | grep <flag>` and test `--help` before writing any automation. Never assume Windows/Linux flag parity for low-level hardware tools.

2. **Test the `expect` script in dry-run before production flash.** Trigger the interactive prompts manually, observe them, then write the expect patterns against observed output — not assumed output.

3. **Document the service dependency graph before writing the flash script.** A quick `lsof /dev/nvidia*` and `systemctl list-units | grep nvidia` snapshot identifies all GPU consumers before the first attempt. This eliminates the module-unload failure entirely.

4. **Verify ROM checksums and subsystem IDs before any flash attempt.** `nvflash --check <rom>` and `lspci -vvv -s <addr> | grep Subsystem` should be run and logged as a pre-flight gate.

5. **Use `lspci -vvv | grep -A5 'Resizable BAR'` as the canonical check** — not `nvidia-smi`. The lspci output shows supported sizes (VBIOS capability) and current assigned size (UEFI allocation) separately, making it unambiguous whether the VBIOS flash and UEFI reallocation both succeeded.

6. **Pre-stage the backup ROM name and hash in the script output** — so post-incident forensics don't require re-reading logs to find which file is the backup.

---

## 8. Final State

| Item | Before | After |
|------|--------|-------|
| RTX 3080 BAR1 Total | 256 MiB | **16 GB** |
| RTX 3080 BAR1 supported sizes | 64MB 128MB 256MB | 64MB … 8GB 16GB |
| RTX 5080 BAR1 Total | 16 GB (native) | 16 GB (unchanged) |
| VBIOS version | 94.02.42.40.65 (AS03) | 94.02.42.40.66 (AS02) |
| Ollama GPU config | Both GPUs, 256 MiB BAR1 on 3080 | Both GPUs, full BAR1 on both |

Backup preserved at `~/vbios-work/3080-backup-pre-rebar.rom`.

---

*Documented 2026-05-17. System: worlock (Ubuntu, kernel 6.8.12). Author: jeb / danindiana.*
