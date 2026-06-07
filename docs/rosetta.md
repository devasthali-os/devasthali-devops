# Rosetta 2 in Lima

Rosetta 2 is Apple's binary translation layer that allows x86_64 (amd64) executables to run
on Apple Silicon (aarch64) Macs. On the macOS host it is transparent. Inside a Lima VM it
requires explicit configuration — and only works with `vmType: vz`.

Referenced from [`lima.md`](./lima.md) and [`cpu-architectures.md`](./cpu-architectures.md).

---

## Why it matters in Lima

An aarch64 Lima guest is a native arm64 Linux VM. Without Rosetta, any binary compiled for
x86_64 produces `exec format error`. This affects:

- Docker images published as amd64-only (no arm64 manifest)
- Proprietary tools that have not yet released arm64 builds
- Legacy CI scripts that download amd64 binaries directly

With Rosetta enabled, the arm64 Lima guest can transparently execute these amd64 binaries —
bridging the binary-compatibility gap described in
[`cpu-architectures.md`](./cpu-architectures.md).

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| Mac hardware | Apple Silicon (M1 or later) |
| macOS version | macOS 13 Ventura or later |
| Lima version | 0.14.0 or later |
| `vmType` | **`vz` only** — Rosetta is not available with `vmType: qemu` |
| Guest arch | `aarch64` (arm64 Linux guest, not an x86_64 guest) |

> Rosetta translates *amd64 binaries running inside an arm64 guest*. It does not turn the
> guest into an x86_64 machine — the kernel and native binaries remain aarch64.

---

## Configuration

```yaml
vmType: vz
rosetta:
  enabled: true
  binfmt: true   # registers binfmt_misc so amd64 ELFs execute transparently
```

With `binfmt: true`, the Linux kernel's `binfmt_misc` subsystem is configured to invoke the
Rosetta interpreter for any ELF binary with an x86_64 magic header. This makes amd64
execution transparent — no wrapper script or explicit flag needed.

---

## Running amd64 Docker images with Rosetta

```bash
# Without --platform: the Docker daemon checks binfmt_misc and uses Rosetta automatically.
docker run --rm ubuntu:latest uname -m
# x86_64   ← Rosetta translated it; kernel reports the emulated arch

# Explicit platform flag still works:
docker run --rm --platform linux/amd64 ubuntu:latest uname -m
```

Build multi-arch images from inside the VM (Rosetta handles the amd64 user-space):

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t myimage:latest .
```

---

## Rosetta vs QEMU TCG

The alternative to Rosetta for running amd64 binaries is `vmType: qemu` with `arch: x86_64`
(full hardware emulation via TCG). Rosetta is dramatically faster:

| | Rosetta 2 (`vmType: vz`) | QEMU TCG (`arch: x86_64`) |
|--|--------------------------|---------------------------|
| Execution model | JIT binary translation (user space) | Dynamic binary translation (system emulation) |
| Overhead vs native | ~1.2–2× | 5–20× |
| JIT compiler support | limited (SMC restrictions) | full |
| Docker amd64 images | ✅ (via binfmt) | ✅ (slow) |
| macOS requirement | Apple Silicon + macOS 13+ | any QEMU host |

**Rule:** prefer Rosetta for day-to-day amd64 compatibility on Apple Silicon. Fall back to
QEMU TCG only when you need exact x86_64 hardware behaviour (e.g., reproducing a specific
SIMD edge case or testing CPU-instruction-sensitive code).

---

## Limitations

- **`vmType: vz` only** — cannot be combined with `vmType: qemu`.
- **Self-modifying code (SMC):** Rosetta restricts memory pages that are simultaneously
  writable and executable, which can break some JITs (certain JVM modes, V8 with specific
  flags). Test your runtime before relying on Rosetta for JIT-heavy workloads.
- **No GPU/ANE access** — Rosetta translates CPU instructions only; CUDA/Metal remain
  unavailable inside the VM regardless.
- **System calls go through the arm64 kernel** — only user-space binary translation. Kernel
  modules or binaries that invoke raw x86-specific syscalls (rare outside kernel dev) will fail.
- **Apple Silicon + macOS 13+ only** — not available on Intel Macs or Linux hosts.

---

## See also

- [`cpu-architectures.md`](./cpu-architectures.md) — binary gap, weak memory ordering, LLM inference placement
- [`acceleration.md`](./acceleration.md) — HVF vs KVM vs TCG performance paths
- [`lima.md`](./lima.md) — full QEMU vs `vz` comparison table
