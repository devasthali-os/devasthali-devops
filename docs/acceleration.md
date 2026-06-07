# VM Acceleration: HVF, KVM, and TCG

Deep-dive companion to [`lima.md`](./lima.md) and [`cpu-architectures.md`](./cpu-architectures.md).
Covers the three execution paths QEMU can take and what they mean for your Lima setup.

## Table of contents

- [The three paths](#the-three-paths)
  - [HVF — Hypervisor.framework (macOS)](#hvf--hypervisorframework-macos)
  - [KVM — Kernel-based Virtual Machine (Linux)](#kvm--kernel-based-virtual-machine-linux)
  - [TCG — Tiny Code Generator (software emulation)](#tcg--tiny-code-generator-software-emulation)
- [How Lima selects the path](#how-lima-selects-the-path)
- [`vmType: qemu` vs `vmType: vz` and acceleration](#vmtype-qemu-vs-vmtype-vz-and-acceleration)
- [See also](#see-also)

---

## The three paths

### HVF — Hypervisor.framework (macOS)

Apple's kernel-level hypervisor API (macOS 10.15+ on Intel, macOS 12+ on Apple Silicon).
When the Lima guest arch matches the host CPU arch, QEMU automatically selects `-accel hvf`.

- Guest CPU instructions run **directly on the physical cores** — no translation layer.
- The hypervisor enforces memory isolation and manages VM exits, but the CPU executes guest
  code natively.
- Near-native speed: typically < 5 % overhead vs bare metal for CPU-bound workloads.
- **Does not expose GPU, ANE, or other accelerators** to the guest. The VM sees CPU only.

Requires: macOS host + guest arch == host arch (aarch64 on Apple Silicon, x86_64 on Intel Mac).

### KVM — Kernel-based Virtual Machine (Linux)

Linux's built-in hypervisor module, loaded as `/dev/kvm`. Uses hardware virtualization
extensions built into the CPU:

- **x86_64:** Intel VT-x (VMCS) or AMD-V (SVM)
- **aarch64:** ARM EL2 hardware virtualization

QEMU uses `-accel kvm` when running on Linux with a matching guest arch. KVM is the Linux
functional equivalent of HVF — same principle, different OS.

Requires: Linux host + kernel module loaded + guest arch == host arch.

### TCG — Tiny Code Generator (software emulation)

QEMU's fallback when no hardware accelerator is available — most commonly when the guest
arch differs from the host:

- **Dynamic binary translation:** guest instructions are translated to host instructions at
  runtime, one "translation block" at a time.
- **5–20× slower** than native. CPU-bound workloads feel this immediately; I/O-bound workloads
  less so, but still noticeably.
- Emulation is *correct* — the guest behaves as if it's on real hardware — but the speed
  cost is significant.
- No hardware virtualization extensions are used; TCG runs in pure user space.

The most common trigger: an amd64 (`x86_64`) Lima guest on an Apple Silicon (`aarch64`) host.

---

## How Lima selects the path

Lima does not expose an explicit `acceleration:` knob. The backend is chosen automatically:

| Host OS | Host arch | Guest arch | vmType | Acceleration |
|---------|-----------|------------|--------|--------------|
| macOS | aarch64 (M-series) | aarch64 | qemu or vz | HVF / vz |
| macOS | x86_64 (Intel) | x86_64 | qemu or vz | HVF / vz |
| macOS | aarch64 | **x86_64** | qemu | **TCG (slow)** |
| Linux | x86_64 | x86_64 | qemu | KVM |
| Linux | aarch64 | aarch64 | qemu | KVM |

**How to check which path you're on:**

```bash
limactl ls
# If ARCH != $(uname -m) → you are on TCG.
```

---

## `vmType: qemu` vs `vmType: vz` and acceleration

Both backends support hardware acceleration for native-arch guests on macOS:

- `qemu` uses HVF (via `-accel hvf`).
- `vz` uses Apple's Virtualization.framework directly — lower overhead, faster boot, and
  enables features like virtiofs and Rosetta that QEMU cannot offer.

For day-to-day Apple Silicon dev, `vz` is the better choice. Use `qemu` when you need
cross-arch emulation (TCG) or when running on Linux (KVM).

---

## See also

- [`glossary.md`](./glossary.md) — definitions of HVF and KVM
- [`file-sharing.md`](./file-sharing.md) — how the mount protocol interacts with backend choice
- [`rosetta.md`](./rosetta.md) — running amd64 binaries in an arm64 guest without TCG
- [`lima.md`](./lima.md) — QEMU vs `vz` comparison table and full Lima reference
- [`cpu-architectures.md`](./cpu-architectures.md) — arch performance cliff and the LLM inference lens
