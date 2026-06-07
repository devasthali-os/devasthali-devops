# AppArmor: A Principal Engineer's Reference

AppArmor ("Application Armor") is a Linux kernel Security Module (LSM) that enforces
**Mandatory Access Control (MAC)** by confining programs to a defined set of resources.
It is active by default on Ubuntu (the OS used inside LiMa guests in this repo) and is
the primary host-side security layer that Docker, containerd, and Kubernetes rely on to
harden containers beyond what namespaces and cgroups alone provide.

---

## 0. Where AppArmor fits in the stack

```
┌──────────────────────────────────────────────────────────┐
│  Container / Pod                                         │
│    process (nginx, sidecar, …)                           │
├──────────────────────────────────────────────────────────┤
│  Container runtime (runc / crun)                         │
│    applies seccomp filter + AppArmor profile at exec()   │
├──────────────────────────────────────────────────────────┤
│  Linux kernel                                            │
│    LSM hook intercepts every syscall that touches a      │
│    labeled resource (file, socket, capability, …)        │
│    → profile allows / denies / logs the access           │
├──────────────────────────────────────────────────────────┤
│  Lima guest OS (Ubuntu)  ←  where AppArmor lives         │
└──────────────────────────────────────────────────────────┘
```

AppArmor operates **inside the Lima VM guest**, not on the macOS host. The macOS host has
no AppArmor (it uses its own TCC / SIP / mandatory sandbox frameworks). Everything below
assumes you are working inside a Lima guest or a Linux host directly.

---

## 1. Core concepts

### Profiles

An AppArmor **profile** is a text file that describes what a single program binary is
allowed to do. Profiles are stored in `/etc/apparmor.d/` and identified by the absolute
path of the confined executable (e.g. `/usr/sbin/nginx`).

A profile specifies:

| Resource type | Example rule |
|---------------|--------------|
| File read/write/exec | `/var/log/nginx/** rw,` |
| Networking | `network inet stream,` |
| Linux capabilities | `capability net_bind_service,` |
| Signal sending | `signal send set=(term) peer=/usr/bin/nginx,` |
| Mount operations | `deny mount,` |
| Unix sockets | `unix (create connect) type=stream,` |

### Enforcement modes

| Mode | Kernel behavior | Use when |
|------|-----------------|----------|
| **enforce** | Denies and logs any access not explicitly allowed | Production — default for Docker's built-in profile |
| **complain** | Logs violations but allows them | Auditing a new application before writing a tight profile |
| **disabled** | Profile loaded but not active | Emergency bypass; avoid in production |
| **unconfined** | No profile loaded at all | Never intentional — indicates the profile was never applied |

Check the mode of any profile:

```bash
aa-status          # summary of all loaded profiles and their modes
cat /sys/kernel/security/apparmor/profiles   # kernel-level view
```

### Labels vs. paths

Unlike SELinux (which labels every file inode), AppArmor is **path-based**: the kernel
matches the pathname of the file being accessed against the rules in the profile. This
makes profiles easier to write but means that hard links, bind mounts, and
`/proc/*/fd/` tricks can sometimes route around a rule — a relevant consideration when
reviewing container escape CVEs.

---

## 2. AppArmor and Docker

Docker ships a built-in profile named `docker-default`. It is loaded automatically into
the kernel when the Docker daemon starts and is applied to every container that does not
specify a custom profile.

### What `docker-default` does

- Denies raw network access (`CAP_NET_RAW` blocked for most containers).
- Blocks access to `/proc/sysrq-trigger`, `/proc/kcore`, `/proc/kmem`, and similar
  sensitive kernel interfaces.
- Denies `mount` syscalls inside the container.
- Restricts writes to `/sys/**` (read-only by default).
- Allows all file access inside the container's overlayfs layer (the profile is
  deliberately coarse at the file level — seccomp handles syscall filtering).

View the profile:

```bash
# inside the Lima guest
cat /etc/apparmor.d/docker   # or the generated path under /var/lib/docker/
```

### Overriding the profile per-container

```bash
# Run with no AppArmor confinement (privileged debugging only)
docker run --security-opt apparmor=unconfined …

# Run with a custom profile already loaded into the kernel
docker run --security-opt apparmor=my-custom-profile …
```

> **Design rule:** Never ship `apparmor=unconfined` in a production manifest. If a
> container legitimately needs extra capabilities (e.g. `NET_ADMIN` for a CNI plugin),
> write a narrow custom profile or use a targeted `securityContext.capabilities.add` and
> keep the AppArmor profile in enforce mode.

---

## 3. AppArmor and Kubernetes

Kubernetes applies AppArmor profiles at the Pod / container level via annotations
(pre-1.30) or the `securityContext.appArmorProfile` field (GA in 1.30+).

### 1.30+ field API (preferred)

```yaml
securityContext:
  appArmorProfile:
    type: RuntimeDefault     # use the container runtime's default (= docker-default or equivalent)
    # type: Localhost        # load a profile that already exists on the node
    # localhostProfile: my-nginx-profile
    # type: Unconfined       # no confinement — avoid in production
```

### Pre-1.30 annotation API (still accepted)

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/<container-name>: runtime/default
    # or: localhost/<profile-name>
    # or: unconfined
```

### Node prerequisite

The profile **must be loaded on every node** that can schedule the Pod. Use a DaemonSet
or a node provisioning step (cloud-init, Ansible, etc.) to push and load custom profiles:

```bash
# Load a profile from a file
apparmor_parser -r -W /etc/apparmor.d/my-nginx-profile

# Confirm it is loaded
aa-status | grep my-nginx-profile
```

If the profile is absent on a node and `type: Localhost` is set, the kubelet will refuse
to start the container — the Pod stays in `Pending` with an event like
`apparmor profile not found: my-nginx-profile`.

---

## 4. Writing a custom profile

### Workflow

1. **Run the application in complain mode** to capture every access it actually makes.
2. **Generate a profile stub** from the audit log.
3. **Tighten the profile**, remove overly broad rules.
4. **Switch to enforce mode** and regression-test.

```bash
# Install tooling (Ubuntu)
apt-get install apparmor-utils auditd

# Create a stub profile for a binary
aa-genprof /usr/sbin/nginx
# → interactively walks you through an exercise run, outputs a profile

# Or load the binary in complain mode manually, exercise it, then scan logs
aa-logprof   # reads /var/log/audit/audit.log or /var/log/syslog and proposes rules
```

### Minimal nginx example

```
#include <tunables/global>

/usr/sbin/nginx {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  capability net_bind_service,
  capability setuid,
  capability setgid,

  /etc/nginx/**           r,
  /var/log/nginx/**       rw,
  /var/www/html/**        r,
  /run/nginx.pid          rw,

  network inet stream,
  network inet6 stream,

  deny /proc/sys/**       w,
  deny /sys/**            w,
}
```

Load and enforce:

```bash
apparmor_parser -r -W /etc/apparmor.d/usr.sbin.nginx
aa-enforce /etc/apparmor.d/usr.sbin.nginx
```

---

## 5. Operational commands

```bash
# Full status — loaded profiles, modes, and confined processes
aa-status

# Put a profile into complain mode (non-destructive audit)
aa-complain /etc/apparmor.d/usr.sbin.nginx

# Put a profile into enforce mode
aa-enforce /etc/apparmor.d/usr.sbin.nginx

# Reload a profile after editing (without restarting the daemon)
apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx

# Disable a profile (unload from kernel)
aa-disable /etc/apparmor.d/usr.sbin.nginx

# View live denials (requires auditd or readable syslog)
grep "apparmor=\"DENIED\"" /var/log/syslog
journalctl -k | grep apparmor
```

---

## 6. AppArmor vs. seccomp — complementary, not redundant

A common interview question: *"If you have seccomp, why do you need AppArmor?"*

| | seccomp | AppArmor |
|---|---------|----------|
| Filters | Syscall numbers + arguments | File paths, network families, capabilities, mounts |
| Layer | Kernel syscall table | LSM hook (after syscall dispatch) |
| Granularity | Per-syscall, per-arg | Per-binary, per-resource path |
| Docker default | `default.json` seccomp profile | `docker-default` AppArmor profile |
| Bypassed by | Using allowed syscalls creatively | Hard links, `/proc/*/fd/` path aliasing |

They defend against different attack surfaces. seccomp reduces the kernel attack surface
(fewer syscalls reachable from a container). AppArmor constrains *what resources* an
already-running process can touch. Both should be active; neither replaces the other.

---

## 7. Interaction with Lima guests

Lima's Ubuntu guests **ship with AppArmor enabled** (`/sys/module/apparmor/parameters/enabled = Y`).
The Docker provisioner installed by `docker-lima.yaml` inherits this — so `docker-default`
is loaded and applied to every container run inside the VM.

Key operational notes:

- If you see container startup failures with `permission denied` errors that disappear
  with `--privileged`, **check AppArmor before assuming a filesystem permission issue**.
  AppArmor denials are silent to the container process (it sees `EACCES` or `EPERM`) but
  are logged in the guest's `journalctl -k`.

- Custom profiles you load inside the Lima guest are **ephemeral** unless you add a
  provisioning step (Lima `provision:` scripts in `docker-lima.yaml`) to reload them
  on VM restart. `/etc/apparmor.d/` contents persist on the disk image, but the kernel
  cache is rebuilt at boot — `apparmor_parser` must run again.

- The Lima `vz` backend (macOS Virtualization.framework) and the `qemu` backend both run
  the same Ubuntu guest kernel, so AppArmor behavior is identical regardless of which
  `vmType` you choose.

---

## See also

- [`glossary.md`](./glossary.md) — definitions for HVF, KVM, TCG
- [`lima.md`](./lima.md) — how the Lima VM guest is structured
- [`acceleration.md`](./acceleration.md) — VM execution paths (HVF / KVM / TCG)
- [AppArmor kernel docs](https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html)
- [Docker AppArmor security profiles](https://docs.docker.com/engine/security/apparmor/)
- [Kubernetes AppArmor](https://kubernetes.io/docs/tutorials/security/apparmor/)
