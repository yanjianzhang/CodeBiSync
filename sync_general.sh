#!/usr/bin/env bash
# Sparse_fusion two-way sync via Mutagen + SSH config alias
# Requires: ssh config entry for remote host, mutagen, rsync

set -euo pipefail

# ---- Config ----
SESSION_NAME="default-sync"                           # no underscores (Mutagen rule)
REMOTE_HOST_ALIAS=""
REMOTE_USER=""
REMOTE_TARGET=""
REMOTE_PATH=""
LOCAL_DIR=""
WATCH_INTERVAL="1"
STATE_ROOT=""
LAST_TRANSFER_FILE=""
REMOTE_URL=""

# ---- Helpers ----
msg() { printf "\033[1;32m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'"; exit 1; }; }

usage() {
  cat <<EOF
Usage: $0 [command] [options]

Commands:
  up        Create/resume sync session (default if omitted)
  down      Pause session
  stop      Terminate session (deletes it)
  pull      One-time rsync from remote -> local
  push      One-time rsync from local  -> remote
  status    Show session status
  watch     Live status bar (Ctrl-C to exit)
  flush     Force flush pending changes
  doctor    Check tools/connectivity

Options:
  --session-name NAME     Session name (default: sparsefusion-sync)
  --remote-host HOST      Remote host alias
  --remote-user USER      Remote user
  --remote-path PATH      Remote path
  --local-dir DIR         Local directory
  --state-root DIR        State root directory

Example:
  $0 up --remote-host xxx.com --remote-user user --remote-path /remote/path --local-dir ./local

EOF
}

# Parse command line arguments
parse_args() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --session-name)
        SESSION_NAME="$2"
        shift 2
        ;;
      --remote-host)
        REMOTE_HOST_ALIAS="$2"
        shift 2
        ;;
      --remote-user)
        REMOTE_USER="$2"
        shift 2
        ;;
      --remote-path)
        REMOTE_PATH="$2"
        shift 2
        ;;
      --local-dir)
        LOCAL_DIR="$2"
        shift 2
        ;;
      --state-root)
        STATE_ROOT="$2"
        shift 2
        ;;
      -*)
        err "Unknown option $1"
        usage
        exit 1
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  # Set the command (first positional argument or "up" by default)
  cmd="${args[0]:-up}"
  
  # Validate required parameters
  if [[ -z "$REMOTE_HOST_ALIAS" || -z "$REMOTE_USER" || -z "$REMOTE_PATH" || -z "$LOCAL_DIR" ]]; then
    err "Missing required parameters"
    usage
    exit 1
  fi

  # Set derived variables
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST_ALIAS}"
  REMOTE_URL="${REMOTE_TARGET}:${REMOTE_PATH}"
  STATE_ROOT="${STATE_ROOT:-${LOCAL_DIR%/}/.sparsefusion-sync}"
  LAST_TRANSFER_FILE="${LAST_TRANSFER_FILE:-${STATE_ROOT}/last-transfer.txt}"
}

relativize_transfer_path() {
  local candidate="${1:-}"

  if [[ -z "${candidate}" ]]; then
    return 1
  fi

  candidate=$(printf '%s' "$candidate" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [[ -z "${candidate}" ]]; then
    return 1
  fi

  local dq='"'
  candidate=${candidate#"$dq"}
  candidate=${candidate%"$dq"}

  local local_root="${LOCAL_DIR%/}"
  local remote_root="${REMOTE_PATH%/}"

  if [[ -n "${local_root}" ]]; then
    candidate=${candidate#${local_root}}
    candidate=${candidate#${local_root}/}
  fi

  if [[ -n "${remote_root}" ]]; then
    candidate=${candidate#${remote_root}}
    candidate=${candidate#${remote_root}/}
  fi

  candidate=${candidate#/}
  if [[ -z "${candidate}" ]]; then
    candidate="."
  fi

  printf '%s\n' "$candidate"
}

extract_relative_path() {
  local line="${1:-}"
  if [[ -z "${line}" ]]; then
    return 1
  fi

  case "$line" in
    monitor*|*unavailable*|Alpha\ scan:*|Beta\ scan:*)
      return 1
      ;;
  esac

  local path
  if [[ "$line" == *:* ]]; then
    path=${line#*:}
  else
    path=$line
  fi

  path=$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [[ -z "${path}" || "${path}" == "(none)" ]]; then
    return 1
  fi

  relativize_transfer_path "$path"
}

cache_recent_transfer_line() {
  local line="${1:-}"
  local rel_path

  rel_path=$(extract_relative_path "$line") || return 1
  mkdir -p "$(dirname "${LAST_TRANSFER_FILE}")"
  printf '%s\n' "$rel_path" >"${LAST_TRANSFER_FILE}"
}

capture_recent_transfer() {
  mkdir -p "$(dirname "${LAST_TRANSFER_FILE}")"

  local tmp
  tmp=$(mktemp -t sparsefusion-status.XXXXXX)
  mutagen sync monitor "${SESSION_NAME}" --long >"${tmp}" 2>/dev/null &
  local monitor_pid=$!
  local -i attempt=0
  local -i have_output=0

  while (( attempt < 30 )); do
    if [[ -s "${tmp}" ]]; then
      have_output=1
      break
    fi
    sleep 0.1
    attempt+=1
  done

  if (( have_output )); then
    sleep 0.2
  fi

  kill "${monitor_pid}" 2>/dev/null || true
  wait "${monitor_pid}" 2>/dev/null || true

  if (( have_output == 0 )); then
    rm -f "${tmp}"
    return 1
  fi

  local path_line
  path_line=$(awk '/Propagation path:/ || /Reconciling file:/ || /Staging file:/ { line=$0 } END { print line }' "${tmp}")
  rm -f "${tmp}"

  if [[ -z "${path_line}" ]]; then
    return 1
  fi

  cache_recent_transfer_line "${path_line}" || return 1
}

# ---- Checks ----
need ssh
need mutagen
need rsync

# Ensure daemon is running (idempotent)
mutagen daemon start >/dev/null 2>&1 || true

# Best-effort SSH probe (don’t fail if interactive auth is needed)
# ssh -q "${REMOTE_TARGET}" exit || true

# ---- Actions ----
pull_once() {
  msg "One-time download (remote -> local) with rsync…"
  mkdir -p "$(dirname "$LOCAL_DIR")"
  rsync -avz --delete \
    -e "ssh" \
    --exclude '.git' \
    --exclude '.venv' \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.log' \
    --exclude '.DS_Store' \
    --exclude 'models' \
    --exclude 'results' \
    "${REMOTE_TARGET}:${REMOTE_PATH}" \
    "$(dirname "$LOCAL_DIR")/"
  msg "Download complete → ${LOCAL_DIR}"
}

push_once() {
  msg "One-time upload (local -> remote) with rsync…"
  rsync -avz --delete \
    -e "ssh" \
    --exclude '.git' \
    --exclude '.venv' \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.log' \
    --exclude '.DS_Store' \
    --exclude 'models' \
    --exclude 'results' \
    "${LOCAL_DIR%/}/" \
    "${REMOTE_TARGET}:${REMOTE_PATH%/}/"
  msg "Upload complete → ${REMOTE_PATH}"
}

watch() {
  msg "Watching session (Ctrl-C to exit)…"
  mutagen sync monitor "${SESSION_NAME}" --long
}

up() {
  # Ensure local dir exists
  mkdir -p "${LOCAL_DIR}"

  # Check if session already exists
  if mutagen sync list | grep -q "Name: ${SESSION_NAME}"; then
    msg "Resuming existing session ${SESSION_NAME}"
    mutagen sync resume "${SESSION_NAME}"
  else
    msg "Creating new session ${SESSION_NAME}"
    mutagen sync create \
      --name="${SESSION_NAME}" \
      --sync-mode=two-way-resolved \
      --ignore-vcs \
      --ignore=".venv" \
      --ignore="node_modules" \
      --ignore="__pycache__" \
      --ignore="*.log" \
      --ignore="models" \
      --ignore="results" \
      "${LOCAL_DIR}" \
      "${REMOTE_URL}"
  fi

  msg "Sync running. Use '$0 status' to inspect."
}

down() {
  mutagen sync pause "${SESSION_NAME}"
  msg "Paused ${SESSION_NAME}"
}

stop() {
  mutagen sync terminate "${SESSION_NAME}"
  msg "Terminated ${SESSION_NAME}"
}

status() {
  local status_output
  if ! status_output=$(mutagen sync list 2>&1); then
    printf '%s\n' "$status_output"
    return 1
  fi

  printf '%s\n' "$status_output"

  if [[ "$status_output" == *"Name: ${SESSION_NAME}"* ]]; then
    capture_recent_transfer || true
  fi

  local recent_path=""
  if [[ -f "${LAST_TRANSFER_FILE}" ]]; then
    recent_path=$(<"${LAST_TRANSFER_FILE}")
  fi

  if [[ -n "$recent_path" ]]; then
    printf '\nMost recent transfer: %s\n' "$recent_path"
  else
    printf '\nMost recent transfer: (unavailable)\n'
  fi
}

flush() {
  mutagen sync flush "${SESSION_NAME}"
  msg "Flushed ${SESSION_NAME}"
}

doctor() {
  msg "Checking tools…"
  for t in ssh mutagen rsync; do
    printf " - %-8s: " "$t"; command -v "$t" || true
  done
  msg "Testing SSH to ${REMOTE_TARGET}…"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_TARGET}" 'echo OK' || err "SSH check failed (may still be fine if auth requires TTY)."
  msg "Remote path: ${REMOTE_PATH}"
  msg "Local  path: ${LOCAL_DIR}"
}

# Main execution
main() {
  parse_args "$@"
  
  # Best-effort SSH probe (don’t fail if interactive auth is needed)
  ssh -q "${REMOTE_TARGET}" exit || true
  
  case "$cmd" in
    up) up ;;
    down) down ;;
    stop) stop ;;
    pull) pull_once ;;
    push) push_once ;;
    status) status ;;
    watch) watch ;;
    flush) flush ;;
    doctor) doctor ;;
    -h|--help|help) usage ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

# Only run main if script is executed, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi