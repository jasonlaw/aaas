#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.env"
ALERT_DIR="${SCRIPT_DIR}/alerts"
LOG_FILE="${SCRIPT_DIR}/watchdog.log"

source "$CONFIG_FILE"

stamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(stamp)" "$*" >>"$LOG_FILE"
}

# alert <alert_code> <message> [key: value ...]
#
# Generic, target-agnostic alert dispatcher. Writes a structured alert.txt
# into a unique timestamped folder and hands the folder to opencode, which
# routes to the matching "<alert_code>-recovery" skill via the
# watchdog-alert skill. Any future watchdog check (docker engine, disk
# space, etc.) reuses this same function unchanged.
#
# alert_code must match the "<alert_code>-recovery" skill name exactly
# (e.g. "hermes-gateway" -> hermes-gateway-recovery). Extra key/value pairs
# are freeform context for the recovery skill (e.g. "gateway_unit: ...").
alert() {
  local alert_code="$1"
  local message="$2"
  shift 2
  local alert_path kv

  alert_path="${ALERT_DIR}/alert-$(date "+%Y%m%d-%H%M%S")-$$"
  mkdir -p "$alert_path"

  {
    printf "alert_code: %s\n" "$alert_code"
    printf "timestamp_utc: %s\n" "$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
    printf "message: %s\n" "$message"
    for kv in "$@"; do
      printf "%s\n" "$kv"
    done
  } >"${alert_path}/alert.txt"

  log "[$alert_code] $message"

  if command -v opencode >/dev/null 2>&1; then
    # No alert-specific detail in the prompt — the watchdog-alert skill
    # reads everything it needs straight out of alert.txt.
    (cd "$PLATFORM_DIR" && opencode run "AaaS watchdog alert. Alert folder: ${alert_path}. Use the watchdog-alert skill.") >>"$LOG_FILE" 2>&1 || true
  fi
}

process_running() {
  pgrep -f "$1" >/dev/null 2>&1
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
  log "Hermes gateway system service is healthy."
  exit 0
fi

log "Hermes gateway system service is not healthy; attempting restart."
if sudo -n systemctl restart "$HERMES_GATEWAY_UNIT" >>"$LOG_FILE" 2>&1; then
  sleep 3
  if sudo -n systemctl is-active --quiet "$HERMES_GATEWAY_UNIT"; then
    log "Hermes gateway system service recovered via systemctl restart."
    exit 0
  fi
fi

# Direct restart failed or didn't stick — hand off to opencode, which
# follows the hermes-gateway-recovery skill for further remediation.
alert "hermes-gateway" \
  "Hermes gateway system service failed to start via 'sudo systemctl restart \"$HERMES_GATEWAY_UNIT\"'" \
  "gateway_unit: $HERMES_GATEWAY_UNIT"
exit 1
