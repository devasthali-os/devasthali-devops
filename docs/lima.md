# LiMa + VVM: A Principal Engineer's Reference

This document is the in-depth companion to `lima-qemu-dockerd.yaml` in this repo. It explains
*how LiMa and QEMU actually work under the hood*, the tradeoffs that matter at scale, and
the operational/security reasoning a principal-level engineer is expected to articulate in
design reviews. It is deliberately opinionated about *why*, not just *what*.

## Table of contents

- [0. The instance in this repo](#0-the-instance-in-this-repo)
- [1. What Lima is (and is not)](#1-what-lima-is-and-is-not)
- [2. QEMU: the layer that actually does the work](#2-qemu-the-layer-that-actually-does-the-work)
- [2.5 CPU architectures (x86_64 vs aarch64)](#25-cpu-architectures-x86_64-vs-aarch64)
- [3. Lifecycle & the control plane](#3-lifecycle--the-control-plane)
- [4. Networking model (and why `host.docker.internal` exists)](#4-networking-model-and-why-hostdockerinternal-exists)
- [5. Filesystem sharing — the second big performance lever](#5-filesystem-sharing--the-second-big-performance-lever)
- [6. Provisioning, probes, and reproducibility](#6-provisioning-probes-and-reproducibility)
- [7. Rootless Docker: the security posture](#7-rootless-docker-the-security-posture)
- [8. Operating it: a practical debugging playbook](#8-operating-it-a-practical-debugging-playbook)
- [9. Scaling considerations (the "at Meta" lens)](#9-scaling-considerations-the-at-meta-lens)
- [10. One-paragraph summary for a design review](#10-one-paragraph-summary-for-a-design-review)

---

## 0. The instance in this repo

```bash
limactl ls
NAME           STATUS     SSH                VMTYPE    ARCH      CPUS    MEMORY    DISK      DIR
lima-qemu-dockerd    Running    127.0.0.1:61221    qemu      x86_64    4       4GiB      100GiB    ~/.lima/lima-qemu-dockerd
```

What each column is really telling you:

| Field | Meaning & what to watch for |
|-------|-----------------------------|
| `VMTYPE = qemu` | Hardware-virtualized guest via QEMU (not the macOS-native `vz` backend). Portable, slowest of the options, supports cross-arch emulation. |
| `ARCH = x86_64` | The *guest* architecture. If your host is Apple Silicon (aarch64), this row means **full CPU emulation via TCG**, which is 5–20x slower than native. On an Intel host it is hardware-accelerated. This single field is the most common silent performance killer. |
| `SSH = 127.0.0.1:61221` | Lima exposes the guest only on loopback via a forwarded SSH port. All control-plane traffic (provisioning, `limactl shell`, file sync triggers) rides this channel. |
| `DISK = 100GiB` | A *sparse* qcow2 image — it does not consume 100 GiB until written. |
| `DIR = ~/.lima/lima-qemu-dockerd` | The instance home: config, disk images, logs, serial console, and the forwarded `docker.sock` all live here. This is the first place you look when debugging. |

> Decode the host/guest arch mismatch immediately: `limactl ls` shows guest arch; `uname -m`
> shows host arch. If they differ and `VMTYPE=qemu`, you are emulating, not virtualizing.

---

## 1. What Lima is (and is not)

**Lima** ("Linux Machines") is a thin orchestration layer that launches Linux VMs on macOS
(and Linux) with **automatic filesystem sharing and port forwarding**, configured
declaratively in YAML. It is the engine behind `colima` and the default backend for
Rancher Desktop's VM mode.

Lima is **not** a hypervisor and **not** a container runtime. It is glue:

```
limactl (Go CLI / control plane)
   │  writes config, manages lifecycle, owns the SSH tunnel
   ▼
QEMU  or  Virtualization.framework (vz)   ← the actual hypervisor
   │
   ▼
Linux guest (cloud-init'd Ubuntu image)
   │  cloud-init + Lima "provision" scripts install Docker, etc.
   ▼
containerd / dockerd / your workload
```

Mental model: **Lima is to local Linux VMs what Vagrant was to VirtualBox** — declarative,
reproducible, disposable — but purpose-built for the container-dev workflow and the
macOS+Apple-Silicon era.

### Why it exists
Docker Desktop is a proprietary product with licensing costs for large orgs. Lima (Apache-2.0)
+ rootless Docker/containerd is the canonical OSS replacement, which is exactly what
`lima-qemu-dockerd.yaml` implements: a Linux VM running **rootless dockerd**, with the Docker socket
forwarded back to the macOS host.

---

## 2. QEMU: the layer that actually does the work

QEMU is a generic machine emulator and virtualizer. Two execution modes matter:

1. **TCG (Tiny Code Generator)** — pure dynamic binary translation. Emulates a *foreign* CPU
   in software. This is what runs an x86_64 guest on an Apple Silicon host. Correct but slow;
   no hardware virtualization extensions are used.
2. **Accelerated (KVM / HVF)** — QEMU defers CPU execution to a hypervisor so guest
   instructions run **natively** on the host CPU. Only possible when guest arch == host arch.
   - On Linux: `-accel kvm` (`/dev/kvm`, Intel VT-x / AMD-V).
   - On macOS: `-accel hvf` (Hypervisor.framework). This is why Intel-Mac x86_64 guests are fast.

### The performance cliff to internalize
| Host | Guest | Acceleration | Relative speed |
|------|-------|--------------|----------------|
| Intel mac (x86_64) | x86_64 | HVF | ~native |
| Apple Silicon (aarch64) | aarch64 | HVF (or `vz`) | ~native |
| Apple Silicon (aarch64) | **x86_64** | **TCG (emulation)** | **slow (5–20x)** |

The repo's image list ships **both** `amd64` and `arm64` cloud images precisely so Lima can
pick the native arch. If you see `x86_64` on an M-series Mac, you are on the slow path — almost
always because something pinned `arch: x86_64` or pulled an amd64-only base image.

### QEMU device model (what Lima wires up)
- **virtio** paravirtualized devices (`virtio-net`, `virtio-blk`/`virtio-scsi`, `virtio-9p`,
  `virtio-rng`) — the guest cooperates with the host instead of pretending to be real hardware,
  which is where most of the I/O performance comes from.
- **qcow2** disk format: copy-on-write, sparse, snapshottable, supports backing files (the
  base cloud image is a read-only backing file; your writes go to an overlay).
- **9p / virtiofs** for the `mounts:` shared directories (more in §5).

### QEMU vs the `vz` backend (the design-review question)
On macOS, Lima can also use Apple's **Virtualization.framework** (`vmType: vz`):

| | QEMU | vz (Virtualization.framework) |
|--|------|-------------------------------|
| Cross-arch emulation | ✅ (TCG) | ❌ native arch only |
| File sharing | 9p (slow) / virtiofs | virtiofs (fast) |
| Networking | user-mode (slirp) / socket_vmnet | vmnet, faster |
| Rosetta x86 binaries | ❌ | ✅ (`rosetta:` translation for amd64 in arm64 guest) |
| Maturity / portability | very mature, portable, Linux too | macOS 13+, Apple Silicon focus |
| Boot speed & overhead | higher | lower |

**Principal-level takeaway:** prefer `vz` + native arch + virtiofs for day-to-day dev speed on
Apple Silicon; reach for **QEMU specifically when you must emulate a different architecture**
(e.g., reproducing an amd64-only production bug, or building multi-arch images without a
remote builder). This repo uses QEMU, so it is portable but pays the emulation tax if run on
arm64 hosts.

**See also:** [`acceleration.md`](./acceleration.md) · [`container-security.md`](./container-security.md) · [`file-sharing.md`](./file-sharing.md) · [`rosetta.md`](./rosetta.md)

---

## 2.5 CPU architectures (x86_64 vs aarch64)

The `arch:` field in `lima-qemu-dockerd.yaml` picks an ISA — **x86_64** (`amd64`) or **aarch64**
(`arm64`). They are not binary-compatible, which is why the repo ships both cloud images and
why the §2 performance cliff exists. For Lima specifically:

- **Match the guest `arch:` to the host** to run native (HVF/`vz`); a mismatch drops you into
  slow QEMU TCG emulation.
- **No GPU/ANE/Metal passthrough into Lima guests** — the VM sees CPU only. Do
  accelerator-bound LLM inference on the macOS **host** or a GPU server, not in the VM.

Full reference — ISA comparison table, per-arch shortcomings, and the LLM/ML-inference lens —
lives in [`cpu-architectures.md`](./cpu-architectures.md).

---

## 3. Lifecycle & the control plane

```bash
limactl start ./lima-qemu-dockerd.yaml      # create + boot (runs cloud-init + provision)
limactl shell lima-qemu-dockerd             # SSH into the guest
limactl stop lima-qemu-dockerd              # graceful ACPI shutdown
limactl delete lima-qemu-dockerd            # destroy disk + state
limactl edit lima-qemu-dockerd              # change YAML; some keys need a restart
limactl factory-reset lima-qemu-dockerd     # wipe back to first-boot
```

This repo ships a thin wrapper, [`devasthali.sh`](../devasthali.sh), so you don't have to
remember the instance name or config path:

```bash
./devasthali.sh start     # create+boot (or resume), then print the docker env line
./devasthali.sh stop      # graceful shutdown
./devasthali.sh restart   # stop + start
./devasthali.sh status    # limactl list for this instance
./devasthali.sh shell     # SSH into the guest
./devasthali.sh delete    # destroy disk + state
```

Override the target with `LIMA_INSTANCE` / `LIMA_CONFIG` env vars.

What `limactl start` actually does, in order:
1. Resolves and **caches the cloud image** (the `digest:` fields pin integrity; cache lives in
   `~/.lima/_cache`, invalidated by `limactl prune`).
2. Generates a cloud-init seed ISO from your YAML (users, SSH keys, the `provision` scripts).
3. Launches QEMU with the qcow2 overlay, virtio devices, and a forwarded SSH port.
4. Waits on **`probes:`** to declare the guest ready (here: docker installed + rootlesskit running).
5. Establishes port forwards, including the **`docker.sock` Unix-socket forward** over SSH.

Key directories inside `~/.lima/lima-qemu-dockerd/`:
- `lima.yaml` — the *materialized* config (your file + defaults). Read this, not just your source YAML.
- `qcow2` disk image(s).
- `serial*.log` — guest console; first stop for boot/kernel failures.
- `ha.stderr.log` / `ha.stdout.log` — the host-agent (forwarding, monitoring) logs.
- `sock/docker.sock` — the forwarded socket referenced by `lima-qemu-dockerd.yaml`.

---

## 4. Networking model (and why `host.docker.internal` exists)

Default Lima/QEMU networking is **user-mode (SLIRP)**: the guest gets NAT'd egress, the host
is reachable as `host.lima.internal`, but the guest is **not** routable from the host except
through explicit forwards. That constraint shapes the whole config:

- **`portForwards:`** maps a guest socket/port to the host. This repo forwards the rootless
  dockerd Unix socket:

```77:79:lima-qemu-dockerd.yaml
portForwards:
- guestSocket: "/run/user/{{.UID}}/docker.sock"
  hostSocket: "{{.Dir}}/sock/docker.sock"
```

  This is what lets the macOS `docker` CLI talk to the in-VM daemon via a `docker context`.

- **`hostResolver` + the `host.docker.internal` shim.** Containers conventionally reach the
  host at `host.docker.internal`. Inside the VM that host is `host.lima.internal`, so the
  config aliases them at two layers:

```72:76:lima-qemu-dockerd.yaml
hostResolver:
  hosts:
    host.docker.internal: host.lima.internal
```

  plus a provision script editing `/etc/hosts` for older Lima where the resolver didn't apply
  inside containers. **Why two mechanisms?** `/etc/hosts` entries in the VM are *not* visible
  to container network namespaces; `hostResolver.hosts` is, because Lima answers DNS for the
  guest and its containers. The script is the backward-compat fallback.

For higher-fidelity networking (stable guest IPs, guest reachable from host, multiple VMs on a
shared L2) Lima supports **`socket_vmnet`** (`networks:` stanza) — relevant when you need the
VM to look like a real host on the LAN.

---

## 5. Filesystem sharing — the second big performance lever

```25:28:lima-qemu-dockerd.yaml
mounts:
- location: "~"
- location: "/tmp/lima"
  writable: true
```

`~` is shared **read-only by default**; `/tmp/lima` is explicitly `writable`. The transport
matters enormously:

- **9p (virtio-9p)** — QEMU default. Correct but slow, with subtle caching semantics
  (`cache=none|loose|mmap|fscache`). Heavy I/O workloads (node_modules installs, big git
  status, compiler temp dirs) feel this acutely.
- **virtiofs** — modern, much faster, FUSE-over-virtio with a host-side daemon. Available with
  `vz`, and increasingly with QEMU. **Preferred** whenever available.
- **reverse-sshfs** — Lima's portable fallback that tunnels the mount over the SSH channel.

**Principal-level guidance:** keep build/scratch directories *inside the guest's own disk*
(native ext4 on virtio-blk) rather than on a shared mount whenever you care about throughput.
Bind-mounting a macOS-side `node_modules` into containers across 9p is a classic, avoidable
performance trap. Share source code; keep hot caches native.

---

## 6. Provisioning, probes, and reproducibility

The guest is configured declaratively in three phases, each idempotent on purpose:

- **`provision: mode: system`** — runs as root during first boot. Here: alias the docker host,
  then `curl get.docker.com | sh`, disable the rootful daemon, install `uidmap`/`dbus-user-session`
  for rootless. Note the guard `command -v docker && exit 0` so re-runs are cheap.
- **`provision: mode: user`** — runs as the Lima user: `dockerd-rootless-setuptool.sh install`,
  switch to the rootless context. This is what makes the daemon run **without root**.
- **`probes:`** — health gates with timeouts. `limactl start` won't report success until docker
  exists *and* `rootlesskit` is running. Probes are how you make "ready" deterministic instead
  of racy.

```59:71:lima-qemu-dockerd.yaml
probes:
- script: |
    #!/bin/bash
    set -eux -o pipefail
    if ! timeout 30s bash -c "until command -v docker >/dev/null 2>&1; do sleep 3; done"; then
      echo >&2 "docker is not installed yet"
      exit 1
    fi
    if ! timeout 30s bash -c "until pgrep rootlesskit; do sleep 3; done"; then
      echo >&2 "rootlesskit (used by rootless docker) is not running"
      exit 1
    fi
  hint: See "/var/log/cloud-init-output.log". in the guest
```

This is infrastructure-as-code at the VM layer: the YAML + pinned image digests give you a
**reproducible, disposable** environment — the property that makes Lima safe to `delete` and
recreate rather than nurse.

---

## 7. Rootless Docker: the security posture

The config deliberately runs **rootless dockerd** (disables the rootful daemon, installs via
`dockerd-rootless-setuptool.sh`). Why this matters at Meta-scale review:

- The Docker daemon traditionally runs as **root**, and access to `docker.sock` is effectively
  **root on the host** (you can bind-mount `/` and escalate). Rootless mode runs the daemon and
  containers inside a **user namespace** via `rootlesskit`, so a container breakout lands you as
  an unprivileged user, not root.
- Trade-offs to call out: no binding to ports <1024 without extra config, some storage drivers /
  cgroup features differ, slightly more setup complexity (hence `uidmap`, `dbus-user-session`,
  the `dbus --user` start). The repo accepts these costs for a materially smaller blast radius.
- **Defense in depth here:** the daemon is unprivileged *and* the whole thing is inside a VM, so
  even a daemon compromise is contained to the guest, not the macOS host. This layered model
  (rootless-in-VM) is the strongest reason to prefer Lima over running Docker natively.
- Outer layers do not remove the need to harden individual containers. See
  [`container-security.md`](./container-security.md) for caps, seccomp, read-only rootfs, and the
  design-review checklist.

---

## 8. Operating it: a practical debugging playbook

| Symptom | First moves |
|---------|-------------|
| Won't boot / hangs at start | `tail -f ~/.lima/lima-qemu-dockerd/serial*.log`; check cloud-init in guest at `/var/log/cloud-init-output.log`. |
| Everything is slow | Confirm `limactl ls` guest arch == host `uname -m`; if mismatched you're in TCG emulation. Then check mount transport (9p vs virtiofs). |
| `docker` on host can't connect | Verify `~/.lima/lima-qemu-dockerd/sock/docker.sock` exists; check the `docker context`; inspect `ha.stderr.log` for forward errors. |
| Provisioning failed | Re-run is idempotent; read `cloud-init-output.log`; probes print which gate failed. |
| Disk filling host | qcow2 is sparse but grows; `docker system prune`, or recreate the instance. |
| Image cache stale / wrong digest | `limactl prune` then `limactl start`. |
| Need to inspect generated config | Read `~/.lima/lima-qemu-dockerd/lima.yaml` (materialized), not just the source YAML. |
Useful one-liners:
```bash
limactl shell lima-qemu-dockerd -- systemctl --user status docker   # rootless daemon health
limactl shell lima-qemu-dockerd -- journalctl --user -u docker      # daemon logs
limactl shell lima-qemu-dockerd -- free -m && nproc                 # resources as the guest sees them
export DOCKER_HOST=$(limactl list lima-qemu-dockerd --format 'unix://{{.Dir}}/sock/docker.sock')
```

---

## 9. Scaling considerations (the "at Meta" lens)

- **Resource sizing.** `4 CPUs / 4 GiB / 100 GiB` is a dev-laptop default. CPUs/memory are
  carved out of the host; oversubscribe across many engineers' machines deliberately, and treat
  guest sizing as a tunable in the YAML, not a constant.
- **Standardization.** The real value is the *checked-in YAML*: one reproducible toolchain image
  across an org beats hand-built Docker Desktop installs. Pin image digests (this repo does) so
  every engineer boots a byte-identical base.
- **Cross-arch CI parity.** QEMU emulation is slow but *invaluable* for reproducing amd64-only
  production behavior on Apple Silicon laptops, and for `docker buildx` multi-arch builds via
  `binfmt_misc` + QEMU user-mode emulators. Know when to pay the tax locally vs offload to a
  remote/native builder farm.
- **Licensing & supply chain.** Lima (Apache-2.0) + OSS Docker sidesteps Docker Desktop
  licensing for large orgs and gives you a fully auditable, declarative bootstrap path.
- **Disposability over pets.** Because the environment is fully described in YAML + pinned
  images, the correct failure response is `delete` + `start`, not manual repair. Build muscle
  memory (and tooling) around recreation.

---

## 10. One-paragraph summary for a design review

> Lima is a declarative orchestrator for local Linux VMs; QEMU (or Apple's
> Virtualization.framework) is the hypervisor underneath. This repo runs an Ubuntu guest under
> **QEMU** with **rootless Docker**, sharing the host filesystem and forwarding the Docker Unix
> socket back to macOS via SSH. The dominant performance variables are **(1) guest/host arch
> match** (mismatch ⇒ slow TCG emulation) and **(2) the shared-filesystem transport** (prefer
> virtiofs/native disk over 9p for hot I/O). The dominant security win is **rootless-daemon-inside-a-VM**,
> which shrinks the blast radius of both a container breakout and a daemon compromise. Everything
> is reproducible from pinned image digests + provisioning scripts, so instances are disposable
> rather than precious.
