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
RM_RC_RECOVERY_INCOMPLETE=21

rm_require_root() {
  printf 'ROOT\n' >>"$CLI_TRACE"
}

tx_reconcile_pending() {
  printf 'RECONCILE\n' >>"$CLI_TRACE"
}

tx_recover_pending() {
  printf 'RECOVER\n' >>"$CLI_TRACE"
}

tx_has_conflict() {
  [[ ${CLI_TX_CONFLICT:-0} == 1 ]]
}
EOF

cat >"$fixture/lib/node.sh" <<'EOF'
upstream_rotation_reconcile_expired() {
  printf 'UPSTREAM\n' >>"$CLI_TRACE"
}
EOF

cat >"$fixture/lib/firewall.sh" <<'EOF'
fw_reconcile_expired() {
  printf 'FIREWALL\n' >>"$CLI_TRACE"
}
EOF

cat >"$fixture/lib/maintenance.sh" <<'EOF'
maintenance_prune_safe() {
  printf 'PRUNE\n' >>"$CLI_TRACE"
}
EOF

for lib in ssh fail2ban backup export update target remove; do
  : >"$fixture/lib/$lib.sh"
done

trace="$root/trace.log"

# A still-valid APPLIED_PENDING transaction is represented by tx_has_conflict.
# Periodic reconcile must preserve it and skip resource pruning.
: >"$trace"
CLI_TRACE="$trace" CLI_TX_CONFLICT=1 RM_TEST_MODE=0 \
  "$fixture/relay-manager.sh" reconcile
grep -Fxq 'ROOT' "$trace" || fail 'reconcile skipped root guard'
grep -Fxq 'RECONCILE' "$trace" || fail 'reconcile did not use deadline-aware transaction reconciliation'
grep -Fxq 'UPSTREAM' "$trace" || fail 'reconcile skipped upstream expiry'
grep -Fxq 'FIREWALL' "$trace" || fail 'reconcile skipped firewall expiry'
if grep -Fxq 'RECOVER' "$trace"; then
  fail 'periodic reconcile used force tx_recover_pending'
fi
if grep -Fxq 'PRUNE' "$trace"; then
  fail 'periodic reconcile pruned resources while a valid pending transaction existed'
fi

# With no transaction conflict, ordinary maintenance pruning still runs.
: >"$trace"
CLI_TRACE="$trace" CLI_TX_CONFLICT=0 RM_TEST_MODE=0 \
  "$fixture/relay-manager.sh" reconcile
grep -Fxq 'RECONCILE' "$trace" || fail 'ordinary reconcile skipped transaction reconciliation'
grep -Fxq 'PRUNE' "$trace" || fail 'ordinary reconcile stopped running maintenance pruning'
if grep -Fxq 'RECOVER' "$trace"; then
  fail 'ordinary periodic reconcile regressed to force recovery'
fi

pass 'periodic reconcile preserves valid pending transactions and still prunes when conflict-free'
