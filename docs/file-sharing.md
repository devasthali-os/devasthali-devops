# File Sharing in Lima: 9p vs virtiofs

Lima's `mounts:` directive exposes macOS host directories inside the Linux guest VM. The
**mount protocol** is the biggest variable in I/O performance for development workloads.

Referenced from [`lima.md`](./lima.md) and [`lima-qemu-dockerd.yaml`](../lima-qemu-dockerd.yaml).

## Table of contents

- [The two protocols](#the-two-protocols)
  - [9p (Plan 9 Filesystem Protocol)](#9p-plan-9-filesystem-protocol)
  - [virtiofs](#virtiofs)
- [Performance comparison](#performance-comparison)
- [Configuration](#configuration)
- [When each matters](#when-each-matters)
- [The WSL 2 parallel on Windows](#the-wsl-2-parallel-on-windows)
- [See also](#see-also)

---

## The two protocols

### 9p (Plan 9 Filesystem Protocol)

The default protocol when `vmType: qemu` is used.

- **Origin:** Bell Labs Plan 9 OS; integrated into Linux as `v9fs` and into QEMU via
  `virtio-9p`.
- **How it works:** file operations (open, read, write, stat, …) are serialized as 9p
  messages and sent over the `virtio-9p` transport between guest and host. Every syscall
  crosses the VM boundary as a round-trip message.
- **Performance:** noticeably slower than native for workloads that make many small file
  operations — `node_modules` installs, git operations, Python imports, build artifact
  scanning.
- **Reliability:** very mature; works across all QEMU targets and Lima versions.

### virtiofs

The high-performance alternative, default with `vmType: vz` and available in `vmType: qemu`
with recent Lima versions.

- **How it works:** uses a shared-memory window (DAX — Direct Access) between host and guest.
  The host FUSE daemon (`virtiofsd`) maps the host directory into shared memory; the guest
  reads/writes that memory directly without serializing every syscall over a transport.
- **Performance:** near-native for most workloads. The round-trip overhead of 9p is
  eliminated. Particularly impactful for build tools and package managers.
- **Requirement:** `mountType: virtiofs` in the Lima YAML (or `vmType: vz`, which implies it).

---

## Performance comparison

| | 9p | virtiofs |
|--|----|----------|
| Transport | virtio-9p message bus | shared memory (DAX) |
| Latency per operation | high (VM boundary crossing) | low (shared memory) |
| Sequential throughput | moderate | near-native |
| Random small I/O | slow | fast |
| Maturity | very mature | stable (macOS 12+ / Lima 0.14+) |
| `vmType` support | qemu (default), vz | qemu + vz |
| Writable mounts | ✅ | ✅ |

---

## Configuration

**Current `lima-qemu-dockerd.yaml` (9p, QEMU default):**

```yaml
mounts:
- location: "~"
- location: "/tmp/lima"
  writable: true
```

No `mountType` specified → Lima defaults to `9p` with `vmType: qemu`.

**Switching to virtiofs with `vmType: vz` (recommended for Apple Silicon):**

```yaml
vmType: vz
mountType: virtiofs
mounts:
- location: "~"
- location: "/tmp/lima"
  writable: true
```

**virtiofs with `vmType: qemu` (Lima 0.14+):**

```yaml
vmType: qemu
mountType: virtiofs
mounts:
- location: "~"
- location: "/tmp/lima"
  writable: true
```

---

## When each matters

- **9p is fine** for config files, occasional reads, and low-frequency mounts.
- **virtiofs is strongly preferred** for:
  - Source code directories with active builds (`go build`, `cargo build`, `npm install`)
  - Git repos (`.git` involves many small random reads/writes)
  - Python virtualenvs and `node_modules`
  - Docker layer cache directories if bind-mounted

---

## The WSL 2 parallel on Windows

Windows's **WSL 2** has the exact same "native vs cross-boundary" performance split as Lima —
just with different names:

| Lima (macOS) | WSL 2 (Windows) |
|--------------|-----------------|
| Guest's own ext4 on `virtio-blk` (fast) | Distro's own ext4 in `ext4.vhdx` (fast) |
| `~` shared over **9p** (slow) / **virtiofs** (fast) | `C:\` mounted at `/mnt/c` over the **9P** protocol / `drvfs` (slow) |
| `host.lima.internal` | `host.docker.internal` |

The takeaway is identical on both platforms: **keep hot, I/O-heavy directories (source trees,
`.git`, `node_modules`, virtualenvs, build caches) on the guest's native Linux filesystem**, not
on the shared host mount. On WSL 2 that means working under `~` inside the distro, never under
`/mnt/c/...`. See [Performance in `docker-windows.md`](./docker-windows.md#6-performance-where-files-live-matters-most).

---

## See also

- [`lima.md`](./lima.md) — full QEMU vs `vz` comparison and Lima reference
- [`docker-windows.md`](./docker-windows.md) — the WSL 2 `/mnt/c` vs ext4 equivalent on Windows
- [`acceleration.md`](./acceleration.md) — how the VM backend affects overall performance
