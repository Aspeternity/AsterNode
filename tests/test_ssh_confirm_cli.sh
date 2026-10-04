#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT

fixture="$root/cli"
mkdir -p "$fixture/lib"
cp "$PROJECT_DIR/relay-manager.sh" "$fixture/relay-manager.sh"
chmod 0755 "$fixture/relay-manager.sh"

cat >"$fixture/lib/system.sh" <<'EOF'
RM_RC_PRECONDITION=10
RM_RC_RECOVERY_INCOMPLETE=21

rm_require_root() {
  printf 'ACCESS root\n' >>"$CLI_TRACE"
}

rm_tty_available() {
  printf 'ACCESS tty\n' >>"$CLI_TRACE"
}

rm_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

tx_recover_pending() {
  printf 'RECOVER\n' >>"$CLI_TRACE"
}
EOF

cat >"$fixture/lib/ssh.sh" <<'EOF'
ssh_confirm_pending() {
  printf 'CONFIRM %s\n' "${1:-}" >>"$CLI_TRACE"
  printf '{"status":"committed_after_manual_verification","transaction_id":"%s"}\n' "${1:-}"
}
EOF

for lib in node firewall fail2ban backup export update target remove maintenance; do
  : >"$fixture/lib/$lib.sh"
done

trace="$root/trace.log"
out="$root/out.json"
: >"$trace"

CLI_TRACE="$trace" RM_TEST_MODE=0 \
  "$fixture/relay-manager.sh" ssh confirm tx-cli-test >"$out"

assert_json "$(cat "$out")" '
  .status=="committed_after_manual_verification" and
  .transaction_id=="tx-cli-test"
'
grep -Fxq 'ACCESS root' "$trace" || fail 'ssh confirm skipped root access guard'
grep -Fxq 'ACCESS tty' "$trace" || fail 'ssh confirm skipped TTY access guard'
grep -Fxq 'CONFIRM tx-cli-test' "$trace" || fail 'ssh confirm did not reach ssh_confirm_pending'
if grep -Fxq 'RECOVER' "$trace"; then
  fail 'ssh confirm ran tx_recover_pending before confirming its pending transaction'
fi

pass 'SSH confirm CLI preserves APPLIED_PENDING transaction until explicit confirm'
