#!/usr/bin/env bash
# multi_windows.sh — tmux dev workspace for the Lima Docker environment.
#
# Windows:
#   monitor  — system load + live docker resource stats  (htop | docker stats)
#   docker   — live container list (docker ps) + interactive docker shell
#   shell    — general-purpose shell with DOCKER_HOST pre-set
#
# Usage:
#   ./multi_windows.sh
#
# Override the Lima instance:
#   LIMA_INSTANCE=lima-qemu-dockerd ./multi_windows.sh

set -euo pipefail

LIMA_INSTANCE="${LIMA_INSTANCE:-lima-vz-dockerd}"
SESSION="devasthali"
TOP_CMD="$(command -v htop 2>/dev/null || echo top)"

# Resolve DOCKER_HOST from the running Lima instance.
if ! DOCKER_HOST_VAL="$(limactl list "${LIMA_INSTANCE}" --format 'unix://{{.Dir}}/sock/docker.sock' 2>/dev/null)"; then
  printf '\033[33mWARN: could not resolve DOCKER_HOST for "%s"; docker panes may not work.\033[0m\n' \
    "${LIMA_INSTANCE}" >&2
  DOCKER_HOST_VAL=""
fi

# Kill any existing session with this name before recreating (idempotent).
tmux kill-session -t "${SESSION}" 2>/dev/null || true

# ── Window: monitor ────────────────────────────────────────────────────────────
# Left pane:  htop / top
# Right pane: docker stats, refreshed every 2 s
tmux new-session -d -s "${SESSION}" -n monitor
tmux send-keys -t "${SESSION}:monitor.0" "${TOP_CMD}" Enter

tmux split-window -h -t "${SESSION}:monitor.0"
tmux send-keys -t "${SESSION}:monitor.1" \
  "DOCKER_HOST='${DOCKER_HOST_VAL}' watch -n 2 docker stats --no-stream" Enter

tmux select-layout -t "${SESSION}:monitor" even-horizontal

# ── Window: docker ─────────────────────────────────────────────────────────────
# Top pane:    watch docker ps (live container list)
# Bottom pane: interactive shell for docker exec / logs / inspect
tmux new-window -t "${SESSION}" -n docker
tmux send-keys -t "${SESSION}:docker.0" \
  "DOCKER_HOST='${DOCKER_HOST_VAL}' watch -n 2 docker ps" Enter

tmux split-window -v -t "${SESSION}:docker.0"
tmux send-keys -t "${SESSION}:docker.1" \
  "export DOCKER_HOST='${DOCKER_HOST_VAL}' && echo \"→ DOCKER_HOST=${DOCKER_HOST_VAL}\"" Enter

# ── Window: shell ──────────────────────────────────────────────────────────────
# Full-screen interactive shell; DOCKER_HOST pre-exported.
tmux new-window -t "${SESSION}" -n shell
tmux send-keys -t "${SESSION}:shell.0" \
  "export DOCKER_HOST='${DOCKER_HOST_VAL}' && echo \"→ DOCKER_HOST=${DOCKER_HOST_VAL}\"" Enter

# Propagate DOCKER_HOST to every future pane / window opened in this session.
[ -n "${DOCKER_HOST_VAL}" ] && tmux set-environment -t "${SESSION}" DOCKER_HOST "${DOCKER_HOST_VAL}"

# Land on the monitor window, left pane.
tmux select-window -t "${SESSION}:monitor"
tmux select-pane   -t "${SESSION}:monitor.0"

tmux attach-session -t "${SESSION}"
