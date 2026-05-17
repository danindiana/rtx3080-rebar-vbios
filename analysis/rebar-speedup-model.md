# ReBAR Speedup Model — RTX 3080 / Ollama Dual-GPU Inference

This document provides a parameterized framework for reasoning about how much
Resizable BAR improves multi-GPU inference throughput, and how to measure the
actual speedup on worlock rather than borrowing numbers from unrelated benchmarks.

---

## The Core Formula

For any workload that moves data across two GPUs over PCIe, the speedup S from
expanding BAR1 is bounded by:

```
S = T_before / T_after
```

Where T is the measured wall-clock time (or the inverse of tokens/sec) for the
same workload, model, and batch size run under identical conditions except for
the BAR1 window size.

### Expanded form

```
Let:
  T_compute   = pure GPU compute time — unchanged by BAR1 size
  T_transfer  = PCIe transfer time for cross-GPU data movement
  B           = BAR1 window size (MiB)
  L           = data transferred per cross-GPU operation (MiB)
  n           = number of cross-GPU transfer operations per inference pass
  r           = remapping cost per BAR window overrun (seconds)

Remapping pressure per operation:
  chunks(L, B) = max(0, ceil(L / B) - 1)

Total remapping overhead:
  O(B) = n × chunks(L, B) × r

Total inference time:
  T(B) = T_compute + T_transfer + O(B)

Speedup when going from B_old = 256 MiB to B_new = 8192 MiB:

  S = T(256) / T(8192)
    = [T_compute + T_transfer + n × chunks(L,  256) × r]
      ──────────────────────────────────────────────────
      [T_compute + T_transfer + n × chunks(L, 8192) × r]
```

### When S is large

S grows when:
- **L >> 256 MiB per operation** — large KV-cache or activation tensors that
  required many BAR re-mappings under the old window
- **n is large** — many cross-GPU exchanges per inference pass (deep models
  split across cards, long context windows)
- **T_compute is small relative to O(B)** — the workload is transfer-bound,
  not compute-bound

### When S ≈ 1.0

S stays near 1.0 when:
- **L ≤ 256 MiB per operation** — transfers already fit in the old BAR window;
  no remapping overhead was occurring
- **T_compute >> O(B_old)** — the model is compute-bound and transfer overhead
  is a small fraction of total time
- **Ollama does not split the model** — if the entire model fits on one GPU,
  there are no cross-GPU transfers regardless of BAR1 size

If S ≈ 1.0 after measurement, the bottleneck was not BAR1. The model is either
compute-bound or not splitting across GPUs.

---

## Measuring S on worlock

**The formula is only as good as S, and S must be measured on the actual
workload — not borrowed from a benchmark with different models, batch sizes,
or GPU configurations.**

### Method 1 — tokens/sec from Ollama output

Ollama already reports tokens/sec per generation. Run the same prompt, same
model, same context length before and after the VBIOS flash and reboot:

```bash
# Before reboot (BAR1 = 256 MiB)
ollama run devstral:24b "explain transformer attention in 200 words"
# Record: eval rate  X tok/s

# After reboot (BAR1 = 8192 MiB)
ollama run devstral:24b "explain transformer attention in 200 words"
# Record: eval rate  Y tok/s

# S = Y / X
```

### Method 2 — wall-clock with GPU utilization logging

```bash
# Log GPU utilization alongside the inference call
nvidia-smi dmon -s u -d 1 > /tmp/gpu-util.log &
DMON_PID=$!

python3 -c "
import time, subprocess
start = time.time()
# your inference call here — e.g. requests.post to Ollama API
elapsed = time.time() - start
print(f'{elapsed:.2f}s')
"

kill $DMON_PID
```

Compare `elapsed` before and after reboot. The `gpu-util.log` will show whether
the GPUs were saturated or idle during the run — useful for diagnosing whether
the workload is compute-bound.

### What to record

```
Model:        <name>
Batch size:   <n>
Context len:  <tokens>
BAR1 (3080):  256 MiB / 8192 MiB
Tokens/sec:   <before> / <after>
S (measured): <after> / <before>
GPU util:     <avg % on GPU 0 and GPU 1>
```

---

## Lower bound: S can be < 1.0 (the dual-GPU BAR caveat)

There is one scenario where enabling ReBAR on the 3080 can *temporarily hurt*
throughput: if the UEFI firmware, when re-negotiating PCIe BAR allocations on
boot, assigns a smaller or mis-aligned window to the RTX 5080 to accommodate
the 3080's newly claimed 8 GB of address space.

This is unlikely on a modern UEFI system with **Above 4G Decoding** properly
enabled — the X570 Taichi has 64-bit BAR space and should have room for both
cards at full size. But it is the exact reason the post-flash verification step
must check **both** GPUs:

```bash
nvidia-smi -q | grep -A3 "BAR1 Memory Usage"
```

Expected after reboot:

```
GPU 00000000:0E:00.0 (RTX 5080)
    BAR1 Memory Usage
        Total   : 16384 MiB    ← unchanged; should not regress
        ...

GPU 00000000:0F:00.0 (RTX 3080)
    BAR1 Memory Usage
        Total   : 8192 MiB     ← expanded from 256 MiB
        ...
```

If the 5080's BAR1 total has regressed from 16384 MiB after enabling ReBAR on
the 3080, the diagnosis is PCIe address space contention. Remedies:
1. Confirm Above 4G Decoding is still enabled in BIOS
2. Check `dmesg | grep -i "BAR\|pci"` for allocation failures on boot
3. Try moving the cards to different PCIe slots to change the enumeration order

---

## Summary admonition

```
Measure S on your actual workload.
Do not borrow S from benchmarks with different models, batch sizes, or GPU configurations.

If S ≈ 1.0 after measurement, the bottleneck was not BAR1.

Verify both GPUs' BAR1 values after reboot — not just the 3080.
```

---

## See also

- [`../README.md`](../README.md) — Flash procedure, ROM selection invariant, post-reboot verification
- [`../LESSONS_LEARNED.md`](../LESSONS_LEARNED.md) — Full project narrative and failure analysis
- [`../diagrams/02_rebar_architecture.svg`](../diagrams/02_rebar_architecture.svg) — BAR1 architecture diagram
