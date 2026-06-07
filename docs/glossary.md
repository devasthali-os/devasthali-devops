# Glossary

Definitions for terms used across this repo's docs. Entries are in alphabetical order.

---

**HVF — Hypervisor.framework**
Apple's kernel hypervisor API, available on macOS 10.15+ on both Intel and Apple Silicon. When
QEMU (or the Lima `vz` backend) detects that the guest arch matches the host arch, it uses HVF
to run guest CPU instructions **directly on the physical cores** — no binary translation. This
is what makes a native-arch Lima VM near-native in speed. HVF does not expose GPU, ANE, or
other accelerators to the guest.

**KVM — Kernel-based Virtual Machine**
Linux's built-in hypervisor module (`/dev/kvm`). On x86_64 Linux it uses Intel VT-x or AMD-V;
on aarch64 Linux it uses ARM hardware virtualization extensions. QEMU uses KVM (via `-accel kvm`)
when running on Linux with a matching guest arch, giving the same near-native performance that
HVF provides on macOS. KVM is not available on macOS; HVF is its functional macOS equivalent.

---

**See also:** [`acceleration.md`](./acceleration.md) — full coverage of HVF, KVM, and TCG execution paths.
