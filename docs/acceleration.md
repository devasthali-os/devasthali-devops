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
- [Windows: WSL 2 and the Windows Hypervisor Platform (WHP)](#windows-wsl-2-and-the-windows-hypervisor-platform-whp)
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

## Windows: WSL 2 and the Windows Hypervisor Platform (WHP)

On Windows the same job is done by **WSL 2**, which runs a Microsoft-built Linux kernel on the
**Windows Hypervisor Platform (WHP)** — the Hyper-V-based accelerator that is the Windows analog
of HVF (macOS) and KVM (Linux). Docker Desktop's WSL 2 backend, and Docker CE installed directly
in a WSL 2 distro, both run on this layer. See [`docker-windows.md`](./docker-windows.md).

Key difference from Lima + QEMU: **WSL 2 has no cross-arch (TCG) mode.** It always runs the
distro at the host's native architecture:

| Host arch | WSL 2 guest arch | Accelerator | Cross-arch emulation |
|-----------|------------------|-------------|----------------------|
| x86_64 | x86_64 | WHP (Hyper-V) | none — native only |
| aarch64 (Windows on Arm) | aarch64 | WHP (Hyper-V) | none — native only |

To run *foreign*-arch binaries inside WSL 2 you register an emulator explicitly (`binfmt_misc` +
`qemu-user-static`, the same user-mode QEMU trick used for `docker buildx` multi-arch builds) —
WSL never silently drops into a slow whole-VM TCG path the way an `arch: x86_64` Lima guest on
Apple Silicon does. That makes the "am I accidentally emulating?" performance cliff a
macOS/Lima concern, not a WSL one.

---

## See also

- [`glossary.md`](./glossary.md) — definitions of HVF, KVM, WHP/Hyper-V, and WSL
- [`file-sharing.md`](./file-sharing.md) — how the mount protocol interacts with backend choice
- [`rosetta.md`](./rosetta.md) — running amd64 binaries in an arm64 guest without TCG
- [`lima.md`](./lima.md) — QEMU vs `vz` comparison table and full Lima reference
- [`docker-windows.md`](./docker-windows.md) — WSL 2 + WHP, the Windows equivalent
- [`cpu-architectures.md`](./cpu-architectures.md) — arch performance cliff and the LLM inference lens
