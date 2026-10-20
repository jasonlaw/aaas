#!/usr/bin/env bash
# Exercises platform/watchdog/watchdog.sh against fake sudo/systemctl/opencode.
# Needs Linux (flock, timeout). Usage: bash tests/watchdog_test.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

WD="$T/platform/watchdog"
mkdir -p "$WD" "$T/bin"
cp "$REPO/platform/watchdog/watchdog.sh" "$WD/"
printf 'HERMES_GATEWAY_UNIT=hermes-gateway.service\n' >"$WD/.env"

# gateway_up: "yes" or "no"; restart_fixes: "yes" makes restart bring it up.
echo no >"$T/gateway_up"
echo no >"$T/restart_fixes"
echo 0 >"$T/opencode_sleep"
echo no >"$T/opencode_removes_folder"

cat >"$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && shift
exec "$@"
EOF
cat >"$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  is-active) [[ "\$(cat $T/gateway_up)" == yes ]] ;;
  restart) [[ "\$(cat $T/restart_fixes)" == yes ]] && echo yes >$T/gateway_up; true ;;
esac
EOF
cat >"$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo "\$*" >>$T/opencode_calls
sleep "\$(cat $T/opencode_sleep)"
if [[ "\$(cat $T/opencode_removes_folder)" == yes ]]; then
  folder="\$(sed -n 's/.*Alert folder: \([^ ]*\)\..*/\1/p' <<<"\$*")"
  rm -rf "\$folder"
fi
EOF
cat >"$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# watchdog.sh sleeps 3s after a restart; keep the test fast.
[[ "$1" == 3 ]] && exit 0
exec /bin/sleep "$@"
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
export WATCHDOG_REPAIR_TIMEOUT=2s

pass=0 fail=0
check() {
  if eval "$2"; then
    printf '[PASS] %s\n' "$1"; pass=$((pass + 1))
  else
    printf '[FAIL] %s\n' "$1"; fail=$((fail + 1))
  fi
}
run() { bash "$WD/watchdog.sh" >/dev/null 2>&1 || true; }
calls() { [[ -f "$T/opencode_calls" ]] && wc -l <"$T/opencode_calls" || echo 0; }
folders() { find "$WD/alerts" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }
state() { cat "$WD/state/hermes-gateway.incident" 2>/dev/null; }
attempts() { sed -n 's/^attempts=//p' "$WD/state/hermes-gateway.incident" 2>/dev/null; }
age_last_attempt() {  # pretend the last attempt happened $1 seconds ago
  sed -i "s/^last_attempt=.*/last_attempt=$(( $(date +%s) - $1 ))/" "$WD/state/hermes-gateway.incident"
}

# 1. Healthy gateway: nothing happens.
echo yes >"$T/gateway_up"
run
check "healthy: no incident, no repair" '[[ ! -e "$WD/state/hermes-gateway.incident" && $(calls) -eq 0 ]]'

# 2. Down but restart fixes it: no incident.
echo no >"$T/gateway_up"; echo yes >"$T/restart_fixes"
run
check "restart recovers: no incident, no repair" '[[ ! -e "$WD/state/hermes-gateway.incident" && $(calls) -eq 0 ]]'
check "restart recovers: logged" 'grep -q "recovered via systemctl restart" "$WD/watchdog.log"'

# 3. Down and restart doesn't help: one incident, one repair.
echo no >"$T/gateway_up"; echo no >"$T/restart_fixes"
run
check "failure: incident opened with attempt 1" '[[ "$(attempts)" == 1 && $(folders) -eq 1 && $(calls) -eq 1 ]]'
check "failure: alert.txt has alert_code" 'grep -q "^alert_code: hermes-gateway" "$WD"/alerts/*/alert.txt'

# 4. Next cycles within backoff: no new folders, no new repairs (was: one per 20s cycle).
for _ in 1 2 3 4 5; do run; done
check "within backoff: 5 more cycles add no repair or folder" '[[ $(calls) -eq 1 && $(folders) -eq 1 ]]'

# 5. Backoff elapsed: second attempt.
age_last_attempt 301
run
check "after 5 min backoff: attempt 2" '[[ "$(attempts)" == 2 && $(calls) -eq 2 ]]'

# 6. Second backoff is longer (20 min): 10 min is not enough.
age_last_attempt 600
run
check "20 min backoff respected at 10 min" '[[ $(calls) -eq 2 ]]'

# 7. Repair removes its folder but the fix didn't hold: new folder, budget NOT reset.
echo yes >"$T/opencode_removes_folder"
age_last_attempt 1201
run
check "attempt 3 runs after 20 min" '[[ "$(attempts)" == 3 && $(calls) -eq 3 ]]'
echo no >"$T/opencode_removes_folder"
age_last_attempt 99999
run
check "removed folder recreated, budget not reset" '[[ $(folders) -eq 1 && "$(attempts)" == 3 && $(calls) -eq 3 ]]'
check "recreated alert.txt records prior attempts" 'grep -q "^repair_attempts_so_far: 3" "$WD"/alerts/*/alert.txt'

# 8. Budget exhausted: no more repairs, however long we wait.
for _ in 1 2 3; do age_last_attempt 99999; run; done
check "budget exhausted: stays at 3 repairs" '[[ $(calls) -eq 3 ]]'
check "budget exhausted: logs waiting for a human" 'grep -q "waiting for a human" "$WD/watchdog.log"'

# 9. Gateway comes back: incident resolved, budget reset.
echo yes >"$T/gateway_up"
run
check "healthy again: incident state removed" '[[ ! -e "$WD/state/hermes-gateway.incident" ]]'
check "healthy again: resolved_utc appended" 'grep -q "^resolved_utc:" "$WD"/alerts/*/alert.txt'

# 10. Stuck repair is killed by the timeout.
rm -rf "$WD/alerts" "$T/opencode_calls"
echo no >"$T/gateway_up"; echo 30 >"$T/opencode_sleep"
start=$(date +%s); run; took=$(( $(date +%s) - start ))
check "stuck opencode killed by timeout (took ${took}s)" '[[ $took -lt 10 ]]'
check "timeout logged" 'grep -q "exited non-zero or timed out" "$WD/watchdog.log"'
echo 0 >"$T/opencode_sleep"

# 11. Concurrent run: second instance skips while the lock is held.
exec 8>"$WD/state/watchdog.lock"; flock 8
# shellcheck disable=SC2034  # read inside check's eval
before=$(calls); age_last_attempt 99999; run
check "lock held: second run skips" '[[ $(calls) -eq $before ]] && grep -q "Another watchdog run is in progress" "$WD/watchdog.log"'
exec 8>&-

# 12. Missing unit name: incident, but still bounded.
rm -rf "$WD/alerts" "$WD/state" "$T/opencode_calls"
printf '' >"$WD/.env"
for _ in 1 2 3; do run; done
check "missing HERMES_GATEWAY_UNIT: one repair, not three" '[[ $(calls) -eq 1 && $(folders) -eq 1 ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
