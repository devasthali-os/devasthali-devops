# Glossary

Definitions for terms used across this repo's docs. Entries are in alphabetical order.

## Table of contents

- [HVF — Hypervisor.framework](#hvf)
- [Hyper-V / WHP — Windows Hypervisor Platform](#hyperv)
- [KVM — Kernel-based Virtual Machine](#kvm)
- [WSL 2 — Windows Subsystem for Linux 2](#wsl)

---

<a id="hvf"></a>
**HVF — Hypervisor.framework**
Apple's kernel hypervisor API, available on macOS 10.15+ on both Intel and Apple Silicon. When
QEMU (or the Lima `vz` backend) detects that the guest arch matches the host arch, it uses HVF
to run guest CPU instructions **directly on the physical cores** — no binary translation. This
is what makes a native-arch Lima VM near-native in speed. HVF does not expose GPU, ANE, or
other accelerators to the guest.

<a id="hyperv"></a>
**Hyper-V / WHP — Windows Hypervisor Platform**
Microsoft's type-1 hypervisor (Hyper-V) and the API surface (WHP) that **WSL 2** and Docker
Desktop's Windows backend run on. It is the Windows functional equivalent of HVF (macOS) and
KVM (Linux): guest CPU instructions run natively on the host cores for a matching arch. Like
HVF, it does not pass a GPU/accelerator through to the Linux guest by default.

<a id="kvm"></a>
**KVM — Kernel-based Virtual Machine**
Linux's built-in hypervisor module (`/dev/kvm`). On x86_64 Linux it uses Intel VT-x or AMD-V;
on aarch64 Linux it uses ARM hardware virtualization extensions. QEMU uses KVM (via `-accel kvm`)
when running on Linux with a matching guest arch, giving the same near-native performance that
HVF provides on macOS. KVM is not available on macOS; HVF is its functional macOS equivalent.

<a id="wsl"></a>
**WSL 2 — Windows Subsystem for Linux 2**
Windows's lightweight Linux VM: a Microsoft-built Linux kernel running on the Windows Hypervisor
Platform (Hyper-V). It is the Windows analog of macOS's **Lima** — it hosts the Docker daemon in
a real Linux VM, shares the host filesystem into the guest, and forwards ports/sockets back to
the host. Conceptually closest to Lima with `vmType: vz` (native-arch, virtiofs). Unlike Lima +
QEMU, WSL 2 has no cross-arch TCG mode; it always runs at the host's native architecture. See
[`docker-windows.md`](./docker-windows.md).

---

**See also:** [`acceleration.md`](./acceleration.md) — full coverage of HVF, KVM, and TCG execution paths.
