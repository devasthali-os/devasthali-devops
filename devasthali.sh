#!/usr/bin/env bash
#
# devasthali.sh — start/stop helper for the Lima Docker VM in this repo.
#
#   ./devasthali.sh start     # create+boot (or resume) the VM, then print docker env
#   ./devasthali.sh stop      # graceful ACPI shutdown
#   ./devasthali.sh restart   # stop then start
#   ./devasthali.sh status    # show instance status
#   ./devasthali.sh shell     # SSH into the guest
#   ./devasthali.sh delete    # destroy the instance (disk + state)
#   ./devasthali.sh env       # print DOCKER_HOST line for the host docker CLI
#
# Override the instance name / config via env:
#   LIMA_INSTANCE=lima-qemu-dockerd  LIMA_CONFIG=./lima-qemu-dockerd.yaml  ./devasthali.sh start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

LIMA_INSTANCE="${LIMA_INSTANCE:-lima-qemu-dockerd}"
LIMA_CONFIG="${LIMA_CONFIG:-${SCRIPT_DIR}/lima-qemu-dockerd.yaml}"

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

require_limactl() {
  if ! command -v limactl >/dev/null 2>&1; then
    err "limactl not found. Install Lima first:  brew install lima"
    exit 1
  fi
}

# Prints the instance status (e.g. Running, Stopped) or empty if it doesn't exist.
instance_status() {
  limactl list "${LIMA_INSTANCE}" --format '{{.Status}}' 2>/dev/null || true
}

print_env() {
  if [ "$(instance_status)" = "Running" ]; then
    info "Point the host docker CLI at this VM with:"
    echo "  export DOCKER_HOST=\$(limactl list ${LIMA_INSTANCE} --format 'unix://{{.Dir}}/sock/docker.sock')"
  fi
}

cmd_start() {
  local status
  status="$(instance_status)"
  case "${status}" in
    Running)
      ok "'${LIMA_INSTANCE}' is already running."
      ;;
    "")
      if [ ! -f "${LIMA_CONFIG}" ]; then
        err "Config not found: ${LIMA_CONFIG}"
        exit 1
      fi
      info "Creating + booting '${LIMA_INSTANCE}' from ${LIMA_CONFIG} ..."
      limactl start --name "${LIMA_INSTANCE}" "${LIMA_CONFIG}"
      ok "'${LIMA_INSTANCE}' is up."
      ;;
    *)
      info "Resuming '${LIMA_INSTANCE}' (was ${status}) ..."
      limactl start "${LIMA_INSTANCE}"
      ok "'${LIMA_INSTANCE}' is up."
      ;;
  esac
  print_env
}

cmd_stop() {
  if [ "$(instance_status)" != "Running" ]; then
    info "'${LIMA_INSTANCE}' is not running; nothing to stop."
    return 0
  fi
  info "Stopping '${LIMA_INSTANCE}' ..."
  limactl stop "${LIMA_INSTANCE}"
  ok "'${LIMA_INSTANCE}' stopped."
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  if [ -z "$(instance_status)" ]; then
    info "'${LIMA_INSTANCE}' does not exist. Run:  ${SCRIPT_NAME} start"
    return 0
  fi
  limactl list "${LIMA_INSTANCE}"
}

cmd_shell() {
  if [ "$(instance_status)" != "Running" ]; then
    err "'${LIMA_INSTANCE}' is not running. Run:  ${SCRIPT_NAME} start"
    exit 1
  fi
  shift || true
  limactl shell "${LIMA_INSTANCE}" "$@"
}

cmd_delete() {
  if [ -z "$(instance_status)" ]; then
    info "'${LIMA_INSTANCE}' does not exist; nothing to delete."
    return 0
  fi
  info "Deleting '${LIMA_INSTANCE}' (disk + state) ..."
  limactl delete --force "${LIMA_INSTANCE}"
  ok "'${LIMA_INSTANCE}' deleted."
}

usage() {
  # Print the leading comment block (skip the shebang), stripping the '# ' prefix.
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
}

main() {
  require_limactl
  local subcmd="${1:-}"
  case "${subcmd}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    restart)  cmd_restart ;;
    status|ls|list) cmd_status ;;
    shell|ssh) cmd_shell "$@" ;;
    delete|rm) cmd_delete ;;
    env)      print_env ;;
    ""|-h|--help|help) usage ;;
    *)
      err "Unknown command: ${subcmd}"
      echo
      usage
      exit 1
      ;;
  esac
}

main "$@"
