# CPU Architectures: x86_64 vs aarch64 (with an LLM lens)

Cross-cutting reference for the two Instruction Set Architectures (ISAs) this repo targets.
Referenced from [`lima.md`](./lima.md) (the `arch:` field in `docker-lima.yaml`), but the
material applies anywhere we pick an arch: container images, CI runners, cloud instance types,
and model-inference placement.

**x86_64** (a.k.a. `amd64`) and **aarch64** (a.k.a. `arm64`) are *not* binary-compatible: an
x86_64 binary cannot run on an aarch64 CPU without emulation/translation, and vice versa. This
single fact drives image selection, build strategy, and — increasingly — where your model
inference actually runs.

## What each one is

| | **x86_64 (amd64)** | **aarch64 (arm64)** |
|--|--------------------|---------------------|
| Origin | Intel/AMD, 64-bit extension of x86 (2003) | ARM 64-bit (ARMv8-A, 2011) |
| ISA style | CISC — variable-length, complex instructions, microcoded | RISC — fixed-length, simpler, load/store |
| Typical hosts | Intel Macs, most cloud VMs, gaming/desktop, on-prem servers | Apple Silicon (M1–M4), AWS Graviton, Ampere, Azure Cobalt, phones, Raspberry Pi |
| Lima image here | `ubuntu-24.04-server-cloudimg-amd64.img` | `ubuntu-24.04-server-cloudimg-arm64.img` |
| Native acceleration | HVF on Intel mac, KVM (VT-x) on Linux | HVF / `vz` on Apple Silicon, KVM on arm servers |
| Memory model | Strong (TSO) — fewer surprises in lock-free code | Weak/relaxed — needs explicit barriers; races surface here that hid on x86 |
| SIMD / vector | SSE/AVX/AVX-512, plus AMX tiles on newer Xeon | NEON (128-bit) + SVE/SVE2 (scalable); Apple adds AMX/undocumented matrix units |
| Ecosystem maturity | Broadest — practically everything ships amd64 | Excellent and rapidly closing; a few proprietary binaries still amd64-only |
| Power efficiency | Higher draw per op (improving) | Markedly better perf/watt — the reason cloud is migrating |

## Shortcomings / gotchas of each

**x86_64 shortcomings**
- **Perf/watt.** Loses decisively to arm in performance-per-watt, which is why hyperscalers push
  Graviton/Cobalt and why your laptop fans spin under emulation.
- **Slow path on Apple Silicon.** On an M-series host an amd64 guest runs under QEMU **TCG
  emulation** (5–20x slower). This is the most common self-inflicted wound when running Lima.
- **Licensing/cost.** amd64 cloud instances are typically pricier than equivalent arm (Graviton)
  for the same throughput on many workloads.
- **ISA cruft.** Decades of backward compatibility (real mode, segmentation, microcode) make
  cores larger and more complex than a clean RISC design.

**aarch64 shortcomings**
- **Binary gaps.** A shrinking but real set of proprietary tools, older Docker images, CUDA-only
  binaries, and vendor SDKs ship **amd64-only**. You hit this as `exec format error` or
  `no matching manifest for linux/arm64`.
- **Weak memory ordering.** Code that "worked" on x86's strong ordering can expose latent data
  races on arm. Great for correctness in the long run, painful during a port.
- **Fragmentation.** "arm64" spans Apple Silicon, Graviton, Ampere, and embedded parts with
  different feature levels (SVE width, crypto extensions). Feature detection matters more.
- **Tooling assumptions.** Build scripts, CI runners, and `Dockerfile`s that hardcode `amd64`
  download URLs silently break.

## The LLM / ML-inference lens

This is where the arch choice stops being academic for an AI-heavy org:

- **Apple Silicon (aarch64) is a unified-memory inference box.** The GPU/Neural Engine share
  system RAM, so a 64–128 GB M-series machine can hold models that would need a discrete GPU
  elsewhere. Tools like **llama.cpp/Ollama/MLX** target arm64 + Metal natively. **But:** Lima
  guests get **no GPU/ANE/Metal passthrough** — a VM sees only CPU. Run local LLM inference
  **on the macOS host**, not inside the Lima guest, if you want the accelerators.
- **GPU reality across both arches in a VM.** Neither QEMU TCG nor `vz` exposes the Mac GPU to
  the Linux guest. CUDA needs an NVIDIA GPU, which exists on **x86_64 Linux servers**, not on
  Apple hardware. So the practical split is: *prototype on host (Metal/MLX), deploy on x86_64+CUDA
  or arm64 server inference.*
- **Emulating x86_64 to run a CUDA/AVX wheel is a trap.** People try to `arch: x86_64` a Lima VM
  on an M-chip to use an amd64-only ML wheel; under TCG it is brutally slow **and** still has no
  GPU. The right answer is an arm64-native wheel, or a remote/native x86_64 GPU box.
- **Quantization makes arm/CPU inference viable.** 4-bit/8-bit GGUF quantization + NEON/SVE means
  arm64 CPUs do meaningful token/sec for small–mid models, narrowing the gap when no GPU is present.
- **Inference cost at scale.** arm64 server inference (Graviton, Ampere) often wins on
  **tokens-per-dollar** for CPU-bound or memory-bandwidth-bound serving; x86_64 + datacenter GPUs
  (or AMX) win on raw throughput for large models. The principal-level call is matching model
  size + latency SLO to the arch/accelerator, not defaulting to one.
- **Multi-arch images are now table stakes.** Ship LLM-serving containers as **multi-arch
  manifests** (`docker buildx --platform linux/amd64,linux/arm64`) so the same tag runs on a
  Graviton fleet and an x86 GPU node. Single-arch images are a portability liability for AI infra.

> **Rule of thumb:** match the guest `arch:` to the host to stay native; treat *cross-arch* as an
> explicit, deliberate cost (reproducing prod, building multi-arch). For LLM work, do
> accelerator-bound inference on bare metal/host or a GPU server — the Lima VM is for the
> *control plane and CPU workloads*, not the matmuls.

---

For definitions of terms such as HVF and KVM, see [`glossary.md`](./glossary.md).
For deeper dives, see [`acceleration.md`](./acceleration.md) and [`rosetta.md`](./rosetta.md).
