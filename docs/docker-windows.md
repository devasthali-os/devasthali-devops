# Installing Docker on Windows: A Principal Engineer's Reference

How to install and run Docker on Windows correctly — with the reasoning a principal-level
engineer is expected to articulate. Windows cannot run Linux containers natively; every option
below is really a question of *which Linux VM* runs the daemon and *how* your Windows tooling
talks to it. Getting that mental model right is what separates a stable setup from one that
mysteriously eats CPU, leaks disk, and breaks bind mounts.

For the equivalent story on macOS, see [`lima.md`](./lima.md). For hardening the containers you
run once Docker is installed, see [`container-security.md`](./container-security.md).

## Table of contents

- [0. The core mental model](#0-the-core-mental-model)
- [1. Choosing a backend: WSL 2 vs Hyper-V](#1-choosing-a-backend-wsl-2-vs-hyper-v)
- [2. Choosing a distribution: Docker Desktop vs alternatives](#2-choosing-a-distribution-docker-desktop-vs-alternatives)
- [3. Prerequisites and enabling WSL 2](#3-prerequisites-and-enabling-wsl-2)
- [4. Installing Docker Desktop](#4-installing-docker-desktop)
- [5. Installing Docker in WSL 2 without Docker Desktop](#5-installing-docker-in-wsl-2-without-docker-desktop)
- [6. Performance: where files live matters most](#6-performance-where-files-live-matters-most)
- [7. Resource limits: taming vmmem/Vmmem](#7-resource-limits-taming-vmmemvmmem)
- [8. Networking model](#8-networking-model)
- [9. Security posture](#9-security-posture)
- [10. Operational playbook](#10-operational-playbook)
- [11. Design-review checklist](#11-design-review-checklist)
- [12. Using WSL as your dev environment](#12-using-wsl-as-your-dev-environment)
- [See also](#see-also)

---

## 0. The core mental model

There is no native Windows Docker daemon for Linux containers. When you run `docker run nginx`
on Windows, the container executes inside a **Linux VM**, and the `docker` CLI on Windows is
just a client talking to a daemon inside that VM over a socket or named pipe.

```
┌─────────────────────────────────────────────┐
│  Windows host                                │
│                                              │
│   docker CLI  ──(named pipe / TCP)──┐        │
│                                     │        │
│   ┌─────────────────────────────────▼─────┐  │
│   │  Lightweight Linux VM (WSL 2 / Hyper-V)│  │
│   │     dockerd  +  containerd  +  runc    │  │
│   │     your containers run HERE           │  │
│   └────────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

Two consequences follow from this, and almost every Windows-Docker problem traces back to one
of them:

1. **A filesystem boundary sits between Windows and the VM.** Bind mounts that cross it
   (`C:\...` into a Linux container) go through a network-style translation layer and are slow.
   Files kept *inside* the Linux VM are fast. This is the single biggest performance lever.
2. **The VM consumes real RAM and CPU**, reported on the host as `vmmem` (WSL 2) or `Vmmem`.
   Left unbounded it will grow to consume most of your machine.

Windows *containers* (Windows base images running on the Windows kernel) are a separate world;
this document is about **Linux containers**, which is what >95% of workloads use.

## 1. Choosing a backend: WSL 2 vs Hyper-V

Docker on Windows can host its Linux VM two ways:

| | **WSL 2** (recommended) | **Hyper-V** (legacy) |
|---|---|---|
| VM management | Managed by the WSL 2 lightweight utility VM | Full Hyper-V VM |
| Startup | Fast, on-demand | Slower |
| Memory | Dynamic — reclaims RAM back to host | Statically reserved |
| Filesystem perf (Linux-native) | Excellent | Good |
| Windows editions | Home + Pro + Enterprise | Pro/Enterprise/Education only |
| Nested virtualization friendliness | Better | Worse |

**Default to WSL 2** unless you have a hard requirement that forces Hyper-V (e.g. certain
enterprise-managed hosts, or you need Windows containers via Hyper-V isolation). WSL 2 gives you
dynamic memory reclaim and dramatically better filesystem performance for Linux-native files.

> Note: WSL 2 and traditional Hyper-V VMs, VirtualBox, or VMware can conflict, because WSL 2
> uses the Windows Hypervisor Platform. Modern versions coexist better than they used to, but if
> you run third-party hypervisors, test carefully.

## 2. Choosing a distribution: Docker Desktop vs alternatives

| Option | What it is | When to pick it |
|---|---|---|
| **Docker Desktop** | Official all-in-one: GUI, CLI, WSL 2 integration, Compose, Kubernetes | Default for most developers; simplest, best-supported path |
| **Docker CE inside WSL 2** | Install the open-source engine directly in an Ubuntu WSL distro | Avoids Docker Desktop licensing; more manual; no GUI |
| **Rancher Desktop** | Open-source alternative, uses containerd/moby + WSL 2 | Docker Desktop license concerns, want Kubernetes built-in |
| **Podman Desktop** | Daemonless, rootless-first alternative | Rootless-by-default posture, OCI-native workflows |

**Licensing matters at work.** Docker Desktop requires a paid subscription for larger companies
(commercial use in organizations above Docker's size threshold). It is free for personal use,
education, and small businesses. If you are in a large org, confirm you have a license or use an
alternative — this is a compliance issue, not just a preference.

For most individual developers, **Docker Desktop with the WSL 2 backend** is the right default.
The rest of this document covers that path and the "Docker CE in WSL 2" path.

## 3. Prerequisites and enabling WSL 2

Requirements:

- Windows 10 version 2004+ (build 19041+) or Windows 11, 64-bit.
- Virtualization enabled in BIOS/UEFI (Intel VT-x / AMD-V). Check with Task Manager →
  Performance → CPU → "Virtualization: Enabled".
- Admin rights to enable Windows features.

Enable WSL 2. On current Windows builds a single command does everything (installs WSL, the
virtual machine platform, and a default Ubuntu distro):

```powershell
# Run in an elevated (Administrator) PowerShell
wsl --install
```

Then reboot. After reboot, confirm you are on version 2 and update the kernel:

```powershell
wsl --update
wsl --set-default-version 2
wsl --list --verbose   # VERSION column should read 2
```

If a distro shows `VERSION 1`, convert it:

```powershell
wsl --set-version Ubuntu 2
```

On older builds where `wsl --install` is unavailable, enable the two features manually, reboot,
then install the kernel update package:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

### 3.1 "WSL has no installed distributions" / reboot required

Two closely related states trip people up on a fresh machine. Both are normal and expected —
they are not errors in your setup.

**A. `wsl --list --verbose` reports no distributions:**

```text
Windows Subsystem for Linux has no installed distributions.
Use 'wsl --list --online' to list available distributions
and 'wsl --install <Ubuntu-26.04>' to install.
```

The WSL *engine* is present but no Linux distro is installed yet. List what's available, then
install one (Ubuntu is the sensible default):

```powershell
wsl --list --online     # see installable distros
wsl --install Ubuntu    # download + install Ubuntu
```

**B. "The requested operation requires elevation" followed by "Changes will not be effective
until the system is rebooted":**

```text
The requested operation requires elevation.
...
The operation completed successfully.
The requested operation is successful. Changes will not be effective until the system is rebooted.
```

On a first install, `wsl --install` enables the *Virtual Machine Platform* / *WSL* Windows
features, and those features only activate after a reboot. Do this:

1. **Reboot Windows.** This is mandatory — the newly enabled features are inactive until you do.
2. After reboot, re-run the install in an **elevated (Administrator) PowerShell**:

   ```powershell
   wsl --install Ubuntu
   ```

3. Ubuntu finishes installing and launches, prompting you to create a **UNIX username and
   password**. Type the password directly into the terminal — it will not echo as you type.
4. Confirm it registered on version 2:

   ```powershell
   wsl --list --verbose        # STATE Running/Stopped, VERSION 2
   ```

> If `wsl --install` still reports it "requires elevation," you are not in an Administrator
> shell. Right-click PowerShell → **Run as administrator** and try again.

## 4. Installing Docker Desktop

1. Download Docker Desktop for Windows from the official Docker site (`docker.com`). Do not use
   third-party mirrors — this is a supply-chain surface.
2. Run the installer. On the config screen, **keep "Use WSL 2 instead of Hyper-V" checked.**
3. Reboot if prompted, then launch Docker Desktop and complete first-run setup.
4. Verify from either PowerShell or a WSL shell:

```powershell
docker version        # Client AND Server should both report
docker run --rm hello-world
```

Enable the WSL 2 integration for the specific distros you develop in:

**Settings → Resources → WSL Integration →** toggle on your Ubuntu (or other) distro. This makes
the `docker` CLI available *inside* that distro talking to the same daemon — which is where you
want to work for performance (see §6).

Recommended Docker Desktop settings out of the box:

- **General → Start Docker Desktop when you sign in:** off unless you use it daily (it holds RAM).
- **Docker Engine (JSON):** pin sane defaults, e.g. log rotation so container logs don't fill disk:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "features": { "buildkit": true }
}
```

## 5. Installing Docker in WSL 2 without Docker Desktop

If licensing or footprint rules out Docker Desktop, install Docker CE directly inside a WSL 2
Ubuntu distro. This gives you a real Linux `dockerd` with no GUI layer.

```bash
# Inside your WSL 2 Ubuntu distro
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key and repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
```

WSL 2 does not run `systemd` by default on older builds, so the daemon won't autostart. Two
options:

**Option A — enable systemd (modern WSL).** Add to `/etc/wsl.conf`, then `wsl --shutdown` from
PowerShell and reopen:

```ini
[boot]
systemd=true
```

With systemd on, `sudo systemctl enable --now docker` works normally.

**Option B — start the daemon manually / on shell start** (older WSL without systemd):

```bash
sudo service docker start
```

Run rootless or add yourself to the `docker` group to avoid `sudo` on every command — but
understand the tradeoff: the `docker` group is **root-equivalent** (see §9).

```bash
sudo usermod -aG docker $USER   # log out/in (wsl --shutdown) to take effect
```

## 6. Performance: where files live matters most

This is the rule that fixes the majority of "Docker on Windows is slow" complaints:

> **Keep your project files inside the Linux filesystem, not on `C:\`.**

- Files under `\\wsl$\Ubuntu\home\you\...` (i.e. the WSL ext4 filesystem) → **fast** native I/O.
- Files under `/mnt/c/Users/you/...` (bind-mounted Windows drive) → **slow**, because every read
  and write crosses the 9P/virtio-fs translation boundary between Windows and the VM.

Concretely:

```bash
# GOOD — clone and work inside the WSL home directory
cd ~
git clone https://github.com/you/project.git
cd project
docker compose up   # bind mounts stay inside Linux → fast
```

```bash
# SLOW — working out of the Windows drive
cd /mnt/c/Users/you/project
docker compose up   # every file op crosses the boundary
```

Editor tip: open the project with **VS Code's WSL remote** (`code .` from inside WSL) so the
editor's file watching and language servers also run Linux-side, avoiding cross-boundary polling.

Other performance levers:

- Prefer **named volumes** over host bind mounts for databases and other write-heavy data —
  they live in the VM's native filesystem.
- Enable **BuildKit** (default on modern Docker) for faster, cache-efficient builds.
- Avoid recursive bind mounts of huge Windows directories (`node_modules`, `.git`) — use
  `.dockerignore` and keep dependencies inside the container/volume.

## 7. Resource limits: taming vmmem/Vmmem

The WSL 2 VM will, by default, grow to consume up to ~50–80% of host RAM and never proactively
returns large amounts until you restart it. Cap it with a `.wslconfig` file in your Windows user
profile: `C:\Users\<you>\.wslconfig`.

```ini
# C:\Users\<you>\.wslconfig
[wsl2]
memory=6GB          # hard cap on VM RAM
processors=4        # CPU cores exposed to the VM
swap=2GB
localhostForwarding=true

# Reclaim freed RAM back to the host (modern WSL)
# autoMemoryReclaim=gradual
```

Apply it by fully restarting WSL from PowerShell:

```powershell
wsl --shutdown
```

If you use Docker Desktop with the Hyper-V backend instead of WSL 2, set limits in
**Settings → Resources** (memory, CPU, disk image size) rather than `.wslconfig`.

Reclaiming disk: the WSL/Docker virtual disk (`ext4.vhdx`) grows but does not shrink
automatically. Prune regularly and compact when needed:

```powershell
docker system prune -a --volumes      # remove unused images/containers/volumes (destructive)
wsl --shutdown
# Optional VHDX compaction (advanced): diskpart / Optimize-VHD
```

## 8. Networking model

- From the Windows host, published container ports are reachable at `localhost:<port>` thanks to
  WSL 2 `localhostForwarding`.
- From inside a container, reach a service running on the Windows host via
  `host.docker.internal` (Docker Desktop provides this DNS name automatically).
- The WSL 2 VM gets its own virtual NIC with a NAT'd address that can change across reboots — do
  not hardcode it. Use `localhost` forwarding and `host.docker.internal` instead.

For the deeper "why `host.docker.internal` exists" discussion (it applies identically on macOS
Lima), see [Networking model in `lima.md`](./lima.md#4-networking-model-and-why-hostdockerinternal-exists).

## 9. Security posture

- **The `docker` group is root-equivalent.** Anyone in it can mount the host filesystem into a
  container and gain root. Only add trusted users; treat WSL distro access accordingly.
- **Prefer rootless mode** where practical for defense in depth. Docker Desktop already runs the
  engine inside an isolated VM, which is itself a strong boundary; rootless adds another layer.
- **Trust the source.** Only install Docker Desktop / Docker CE from official Docker channels and
  verify the apt repository GPG key as shown in §5. The installer and daemon are high-value
  supply-chain targets.
- **Keep it updated.** The Linux kernel inside WSL 2, the Docker engine, and Docker Desktop all
  ship security fixes. `wsl --update` and Docker's auto-update should stay on.
- Once Docker is installed, harden the *containers* you run — see
  [`container-security.md`](./container-security.md) for runtime flags, capability dropping, and
  read-only root filesystems, and [`apparmor.md`](./apparmor.md) for LSM profiles.

## 10. Operational playbook

Common failure modes and the first thing to check:

| Symptom | Likely cause | First move |
|---|---|---|
| `docker` command not found in WSL | WSL integration off / CLI not installed in distro | Docker Desktop → Settings → WSL Integration; or install CLI in distro |
| Daemon won't start in WSL (no Desktop) | systemd off, `dockerd` not running | Enable `systemd=true` in `/etc/wsl.conf` or `sudo service docker start` |
| Everything is slow | Files on `/mnt/c` instead of WSL fs | Move project into `~` inside WSL (§6) |
| `vmmem` eating all RAM | No `.wslconfig` cap | Add `[wsl2] memory=` cap and `wsl --shutdown` (§7) |
| Disk keeps growing | `ext4.vhdx` never shrinks | `docker system prune -a`, then compact (§7) |
| Cannot reach host service from container | Using wrong hostname | Use `host.docker.internal` (§8) |
| Port not reachable from Windows | localhost forwarding / not published | Publish with `-p`, confirm `localhostForwarding=true` |
| Virtualization errors on install | VT-x/AMD-V disabled, or hypervisor conflict | Enable virtualization in BIOS; check third-party hypervisors |
| "WSL has no installed distributions" | Engine present, no distro installed | `wsl --install Ubuntu` (§3.1) |
| "Changes will not be effective until reboot" | Install enabled WSL/VM Platform features | Reboot, then re-run `wsl --install Ubuntu` as admin (§3.1) |

Quick health check:

```powershell
wsl --status
wsl --list --verbose
docker info
docker version
```

## 11. Design-review checklist

- [ ] WSL 2 backend selected (not Hyper-V) unless a hard requirement dictates otherwise.
- [ ] Licensing confirmed for Docker Desktop in a commercial org, or an alternative chosen.
- [ ] Virtualization enabled in BIOS; `wsl --list --verbose` shows VERSION 2.
- [ ] Project files live in the WSL ext4 filesystem, not `/mnt/c`.
- [ ] `.wslconfig` caps memory/CPU; `autoMemoryReclaim` considered.
- [ ] Log rotation configured so container logs don't fill the VHDX.
- [ ] Docker installed only from official channels; apt GPG key verified.
- [ ] `docker` group membership limited to trusted users (root-equivalent).
- [ ] Update path in place: `wsl --update` + engine/Desktop updates on.
- [ ] Container-level hardening followed per `container-security.md`.

## 12. Using WSL as your dev environment

Once WSL 2 is running, the sane workflow is to treat the Ubuntu distro as your *primary*
development box and Windows as just the window manager. A few facts make this click:

- **WSL Ubuntu is a fresh, separate Linux install.** Tools installed on Windows are **not**
  visible inside Ubuntu, and vice versa. You install your toolchain *inside* WSL with `apt`.
- **`~` is different in each world.** In PowerShell, `~` = `C:\Users\you`. In WSL, `~` =
  `/home/you`. Running `mkdir ~/foo` in PowerShell makes a *Windows* folder, not a Linux one.
- **Keep code under `~` (any folder name), never `/mnt/c`.** The folder name (`~/dev`, `~/code`,
  `~/rai-linux`, …) is pure taste; what matters is that it lives on the Linux ext4 filesystem for
  fast native I/O (see §6).

### Launch straight into WSL (skip typing `wsl` every time)

- **Windows Terminal:** `Ctrl+,` → **Startup → Default profile → Ubuntu**. New windows open
  directly in WSL.
- **Ubuntu app:** the distro adds an *Ubuntu* entry to the Start menu — pin it to the taskbar; it
  opens in your Linux `$HOME`.
- **Shortcut / command:** `wsl ~` forces the shell to start in your Linux home rather than
  inheriting PowerShell's `/mnt/c/...` directory.

### First-time bootstrap (run once, inside WSL)

The Ubuntu base image ships `bash`, core utils, `apt`, and usually `python3`. Install the rest as
needed — it persists across sessions, so you do **not** reinstall each login:

```bash
sudo apt update && sudo apt upgrade -y            # always first
sudo apt install -y git build-essential python3-venv python3-pip

# Node via nvm (better version control than apt)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
# reopen the shell, then:
nvm install --lts

# Docker: enable Docker Desktop's WSL integration (§4), or install Docker CE in-distro (§5)
```

### Daily loop

```bash
# Open Windows Terminal (default profile = Ubuntu) → you're already in WSL
cd ~/rai-linux/project
code .                # VS Code WSL remote — editor runs Linux-side
docker compose up     # or npm run dev, pytest, … all Linux-native
```

### Mental model

| | Windows side | WSL / Ubuntu side |
|---|---|---|
| Package manager | winget / installers | `apt` |
| Dev toolchain | keep off | **install here** |
| `~` resolves to | `C:\Users\you` | `/home/you` |
| Where code lives | avoid (`/mnt/c` = slow) | ✅ `~/...` (fast ext4) |

## See also

- [Lima + QEMU reference](./lima.md) — the macOS equivalent of this VM-backed Docker model
- [Container security](./container-security.md) — hardening containers at build and runtime
- [AppArmor](./apparmor.md) — LSM profiles for Docker and Kubernetes
- [Glossary](./glossary.md) — definitions for terms used across the repo
