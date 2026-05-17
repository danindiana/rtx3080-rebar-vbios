# BAR1 Mechanics — Why Aperture Size Drives CPU Overhead

This document explains the microarchitectural mechanism by which a small BAR1 window
creates CPU overhead, why that overhead is serializing rather than merely additive, and
why it is especially pronounced for LLM inference on the RTX 3080.

See also: [`rebar-speedup-model.md`](rebar-speedup-model.md) for the parameterized
speedup formula and empirical measurement methodology.

---

## The fundamental constraint

BAR1 is a memory-mapped I/O window. The CPU accesses GPU VRAM by writing to physical
addresses that the PCIe root complex maps to the GPU. The size of BAR1 is the size of
that window — how much VRAM the CPU can address simultaneously without remapping.

With 256 MiB BAR1 on a 10 GB card:

```
256 / 10240 = 2.5% of VRAM visible to the CPU at any moment
```

To access any VRAM beyond the current 256 MiB window, the driver must slide the
aperture to a new position.

---

## What happens at 256 MiB

To move data into VRAM beyond the current aperture, the driver must:

1. **Write new BAR base address** — a PCIe configuration write that repositions the
   256 MiB window to point at a different region of VRAM
2. **Wait for the remap flush** — the remap write must complete and be visible to the
   CPU before the next transfer begins; this requires a PCIe configuration cycle to
   complete, not just a posted write
3. **Transfer the next chunk**
4. **Repeat** until the full allocation is populated

Each remapping operation is **serializing**. The remap must complete before the new
addresses are valid. The transfer cannot begin until the remap is confirmed. You cannot
pipeline the remap with the data movement.

On a PCIe Gen4 x16 link (~32 GB/s peak), the transfer bandwidth itself is not the
bottleneck. The remap latency is.

### The four CPU-side costs per remap epoch

**TLB pressure.** The kernel's IOMMU and the CPU's own TLB must track the BAR mapping.
Each remap potentially invalidates TLB entries covering the old BAR region and installs
new ones. TLB shootdowns on multi-core systems require inter-processor interrupts (IPIs)
to synchronize — every core must acknowledge the invalidation before the remap is safe to
use. On the Ryzen 9 5950X (32 threads), this IPI broadcast happens on every remap epoch.

**Cache coherency overhead.** Writes through MMIO are typically uncacheable
(write-combining at best). With a 256 MiB window, the driver issues many more discrete
MMIO write sequences. Each sequence has fixed overhead: setting up the write-combining
buffer, flushing it with SFENCE or equivalent, and waiting for the PCIe posted write to
drain to the root complex.

**Driver remap lock contention.** The NVIDIA driver serializes BAR remap operations
globally. If multiple CPU threads are trying to populate different VRAM allocations
concurrently — common in a heterogeneous pipeline where the CPU is feeding both GPUs
simultaneously — they queue behind the same remap lock. With 8 GiB BAR1, remapping is
rarely needed for typical LLM weight tensors, so this lock is effectively uncontested.

**CPU stall on completion fences.** For operations that require knowing the data arrived
(staging a tensor before launching a kernel), the CPU must issue a read-back or wait on
a fence. With repeated remaps, each of those fences covers a smaller chunk, multiplying
the number of synchronization points per model load.

---

## Why 8192 MiB changes this

An 8 GiB BAR1 on a 10 GB card means nearly the entire framebuffer is permanently
CPU-addressable without any remapping. The driver maps VRAM allocations once at
allocation time. Subsequent transfers go directly to the correct physical VRAM address
without any remap-flush-transfer cycle.

The PCIe bandwidth is still the ceiling, but you approach that ceiling instead of
spending time in remap overhead. The practical effect is that transfers become
**throughput-bound** rather than **latency-bound** — which is why the speedup is real
but also why it is workload-dependent. If transfers were already small enough to fit in
256 MiB, the remap cost was low and S ≈ 1.0.

---

## LLM-specific amplification

Transformer weight tensors for a 7B+ parameter model are many gigabytes. Loading or
updating them requires populating large contiguous VRAM regions. With 256 MiB BAR1 this
is worst-case for the remap problem — many sequential remaps, each with its TLB,
coherency, and synchronization overhead, for a workload where the CPU has nothing useful
to do while waiting for the remap to flush.

This is why the 3080 specifically shows a large S for model-load-heavy workloads. The
model is large relative to 256 MiB, the CPU is the bottleneck during population, and the
remap overhead dominates. With 8 GiB BAR1 that overhead collapses and the PCIe link
becomes the actual limit.

---

## The concrete numbers

```
RTX 3080 observed working set:  8778 MiB
256 MiB BAR1 aperture epochs:   ceil(8778 / 256)  = 35 epochs
8192 MiB BAR1 aperture epochs:  ceil(8778 / 8192) = 2 epochs

Ratio:  35 / 2 = 17.5× fewer remap operations

For full 10 GiB card:
  ceil(10240 / 256)  = 40 epochs
  ceil(10240 / 8192) = 2 epochs
  Ratio: 20× fewer
```

A PCIe Gen4 remap cycle costs roughly 1–4 µs of serialized latency depending on system
topology. At 4 µs per epoch:

```
256 MiB BAR1:   35 × 4 µs = 140 µs minimum serialized overhead per full VRAM population
8192 MiB BAR1:   2 × 4 µs =   8 µs
```

This 140 µs does not include TLB shootdown IPI latency, write-combining flush time,
driver lock wait, or completion fences — all of which scale with core count and system
load. For pipelines that repopulate VRAM repeatedly (swapping models, loading context,
staging batches), the savings compound across every load.

---

## Important correction: normal CUDA copies are not CPU stores into BAR1

For ordinary model loading, the transfer path is typically:

```
disk → system RAM → pinned/staged host memory → PCIe DMA engine → VRAM
```

The CPU is not usually performing a literal `memcpy()` into GPU VRAM through BAR1 for
every byte. CUDA memory-copy APIs (`cudaMemcpy`, etc.) hand the transfer to the DMA
engine; the driver and runtime handle the transfer machinery.

ReBAR does **not** increase PCIe bandwidth. The same bytes still cross the same PCIe
link. The savings are:

```
less BAR-window remapping
less driver bookkeeping
less TLB / IPI synchronization
fewer completion fences
better conditions for concurrent host-to-device requests
```

This is the correct framing — ReBAR is a reduction in coordination overhead, not a
free bandwidth upgrade.

---

## The warehouse analogy

A 256 MiB BAR1 is like loading a warehouse through a small service hatch:

```
Open hatch to shelf 0     → move 256 MiB of boxes
Repoint hatch to shelf 1  → move 256 MiB
Repoint hatch to shelf 2  → move 256 MiB
...
repeat 35 times
```

An 8192 MiB BAR1 is like opening a full loading-bay door:

```
Open loading-bay door      → move 8192 MiB in one pass
Handle the 586 MiB tail   → done
```

Same mass of boxes. Same truck. Much less door management.

---

## Summary

```
256 MiB BAR1 = many small windows into VRAM.
8192 MiB BAR1 = one large window into most of VRAM.

Same bytes.
Fewer mappings.
Less CPU/driver bookkeeping.
Fewer serializing stalls.
Better heterogeneous-GPU behavior when both cards are active.

Not guaranteed faster unless S_measured confirms it on the actual workload.
```

---

## Diagrams

- [Diagram 06 — BAR1 Window Epochs](../diagrams/06_bar1_window_epochs.svg) — 35 vs 2 aperture windows for the observed 8778 MiB working set
- [Diagram 07 — Remap Cycle Flow](../diagrams/07_remap_cycle_flow.svg) — serialized remap-flush-transfer vs map-once path
- [Diagram 08 — CPU Overhead Breakdown](../diagrams/08_cpu_overhead_breakdown.svg) — four cost components per epoch, scaled by remap count
