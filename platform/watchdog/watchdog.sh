#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.env"
ALERT_DIR="${SCRIPT_DIR}/alerts"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_FILE="${SCRIPT_DIR}/watchdog.log"

source "$CONFIG_FILE"

# Repair budget per incident: at most WATCHDOG_MAX_REPAIRS opencode runs,
# each capped at WATCHDOG_REPAIR_TIMEOUT, spaced by WATCHDOG_BACKOFF
# seconds (one entry per attempt after the first).
WATCHDOG_MAX_REPAIRS="${WATCHDOG_MAX_REPAIRS:-3}"
WATCHDOG_REPAIR_TIMEOUT="${WATCHDOG_REPAIR_TIMEOUT:-15m}"
read -r -a WATCHDOG_BACKOFF <<<"${WATCHDOG_BACKOFF:-300 1200 3600}"

stamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(stamp)" "$*" >>"$LOG_FILE"
}

mkdir -p "$STATE_DIR"

# systemd's Restart=always loop runs one instance at a time, but a manual
# run alongside it must not start a second repair.
exec 9>"${STATE_DIR}/watchdog.lock"
if ! flock -n 9; then
  log "Another watchdog run is in progress; skipping."
  exit 0
fi

# alert <alert_code> <message> [key: value ...]
#
# Target-agnostic incident handler. The first failure for an alert_code
# opens one incident (one alert folder); later failures reuse it instead
# of creating new folders. opencode is run with a timeout, a limited
# number of attempts, and backoff between them, then the incident is left
# for a human.
#
# alert_code must match the "<alert_code>-recovery" skill name exactly
# (e.g. "hermes-gateway" -> hermes-gateway-recovery). Extra key/value pairs
# are freeform context for the recovery skill (e.g. "gateway_unit: ...").
alert() {
  local alert_code="$1"
  local message="$2"
  shift 2
  local state_file="${STATE_DIR}/${alert_code}.incident"
  local alert_path="" attempts=0 last_attempt=0 now kv wait_s

  now="$(date +%s)"
  # shellcheck disable=SC1090
  [[ -f "$state_file" ]] && source "$state_file"

  # The repair skill removes the folder after reporting, even when its fix
  # didn't hold. Recreate it, but keep the attempt count: only an observed
  # healthy check (resolve_incident) resets the repair budget.
  if [[ -z "$alert_path" || ! -d "$alert_path" ]]; then
    alert_path="${ALERT_DIR}/alert-$(date "+%Y%m%d-%H%M%S")-$$"
    mkdir -p "$alert_path"
    {
      printf "alert_code: %s\n" "$alert_code"
      printf "timestamp_utc: %s\n" "$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
      printf "message: %s\n" "$message"
      for kv in "$@"; do
        printf "%s\n" "$kv"
      done
      printf "repair_attempts_so_far: %s\n" "$attempts"
    } >"${alert_path}/alert.txt"
    log "[$alert_code] Incident opened: $message"
  fi

  if (( attempts >= WATCHDOG_MAX_REPAIRS )); then
    log "[$alert_code] Still failing after ${attempts} repair attempt(s); waiting for a human. See ${alert_path}"
    write_incident "$state_file" "$alert_path" "$attempts" "$last_attempt"
    return
  fi

  if (( attempts > 0 )); then
    wait_s="${WATCHDOG_BACKOFF[attempts - 1]:-${WATCHDOG_BACKOFF[-1]}}"
    if (( now - last_attempt < wait_s )); then
      write_incident "$state_file" "$alert_path" "$attempts" "$last_attempt"
      return
    fi
  fi

  attempts=$((attempts + 1))
  write_incident "$state_file" "$alert_path" "$attempts" "$now"

  if ! command -v opencode >/dev/null 2>&1; then
    log "[$alert_code] opencode not found; incident left for a human. See ${alert_path}"
    return
  fi

  log "[$alert_code] Repair attempt ${attempts}/${WATCHDOG_MAX_REPAIRS} (timeout ${WATCHDOG_REPAIR_TIMEOUT})."
  # No alert-specific detail in the prompt — the watchdog-alert skill
  # reads everything it needs straight out of alert.txt. fd 9 (the lock)
  # is closed for the child so a process it leaves behind can't hold the
  # lock and block later checks.
  (cd "$PLATFORM_DIR" && timeout "$WATCHDOG_REPAIR_TIMEOUT" \
    opencode run "AaaS watchdog alert. Alert folder: ${alert_path}. Use the watchdog-alert skill." 9>&-) \
    >>"$LOG_FILE" 2>&1 || log "[$alert_code] Repair attempt ${attempts} exited non-zero or timed out."
}

write_incident() {
  printf "alert_path=%q\nattempts=%q\nlast_attempt=%q\n" "$2" "$3" "$4" >"$1"
}

resolve_incident() {
  local alert_code="$1"
  local state_file="${STATE_DIR}/${alert_code}.incident"
  local alert_path=""

  [[ -f "$state_file" ]] || return 0
  # shellcheck disable=SC1090
  source "$state_file"
  if [[ -n "$alert_path" && -d "$alert_path" ]]; then
    printf "resolved_utc: %s\n" "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" >>"${alert_path}/alert.txt"
  fi
  rm -f "$state_file"
  log "[$alert_code] Incident resolved."
}

# HERMES_GATEWAY_UNIT is written into CONFIG_FILE by install.sh's
# persist_hermes_gateway_unit(). Controlled via plain systemctl, not the
# `hermes` CLI — the hermes CLI's guard wrapper (blocks non-aaas) and the
# --system subcommands' root requirement can never both be satisfied by a
# single process. systemctl sidesteps this: the unit's own User=aaas
# directive execs the process as aaas at the OS level. Matching NOPASSWD
# sudoers grant installed by ensure_watchdog_systemctl_sudo() in install.sh.
if [[ -z "${HERMES_GATEWAY_UNIT:-}" ]]; then
  alert "hermes-gateway" "HERMES_GATEWAY_UNIT is not set in ${CONFIG_FILE}; rerun install.sh to regenerate it"
  exit 1
fi

if sudo -n systemctl is-active --quiet "$HERMES_GATEWAY_UNIT"; then
  resolve_incident "hermes-gateway"
  exit 0
fi

log "Hermes gateway system service is not healthy; attempting restart."
if sudo -n systemctl restart "$HERMES_GATEWAY_UNIT" >>"$LOG_FILE" 2>&1; then
  sleep 3
  if sudo -n systemctl is-active --quiet "$HERMES_GATEWAY_UNIT"; then
    log "Hermes gateway system service recovered via systemctl restart."
    resolve_incident "hermes-gateway"
    exit 0
  fi
fi

# Direct restart failed or didn't stick — hand off to opencode, which
# follows the hermes-gateway-recovery skill for further remediation.
alert "hermes-gateway" \
  "Hermes gateway system service failed to start via 'sudo systemctl restart \"$HERMES_GATEWAY_UNIT\"'" \
  "gateway_unit: $HERMES_GATEWAY_UNIT"
exit 1
