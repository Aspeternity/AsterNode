#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

case_commit_and_rollback() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' > "$dest"
  src=$(mktemp); printf 'new\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  id=$(tx_begin unit-change)
  tx_stage_file "$id" "$src" "$dest" 0600 root:root
  assert_file_mode "$(tx_file "$id")" 600
  assert_file_mode "$(tx_dir "$id")" 700
  assert_file_mode "$(jq -r '.files[0].staged' "$(tx_file "$id")")" 600
  assert_file_mode "$(jq -r '.files[0].snapshot' "$(tx_file "$id")")" 600
  tx_apply "$id"
  assert_eq 'new' "$(cat "$dest")"
  tx_commit "$id"
  assert_eq COMMITTED "$(jq -r .status "$(tx_file "$id")")"

  src2=$(mktemp); printf 'newer\n' > "$src2"
  id2=$(tx_begin unit-rollback)
  tx_stage_file "$id2" "$src2" "$dest" 0600 root:root
  tx_apply "$id2"
  tx_rollback "$id2" test-rollback
  assert_eq 'new' "$(cat "$dest")"
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id2")")"
  rm -f "$src2"
)

case_stale_plan_rejected() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'base\n' > "$dest"
  src=$(mktemp); printf 'planned\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  id=$(tx_begin stale-plan); tx_stage_file "$id" "$src" "$dest"
  printf 'external\n' > "$dest"
  set +e; tx_apply "$id" >/dev/null 2>&1; rc=$?; set -e
  assert_eq 10 "$rc" 'stale plan did not return precondition exit code'
  assert_eq external "$(cat "$dest")" 'stale plan overwrote external change'
  assert_eq PREPARED "$(jq -r .status "$(tx_file "$id")")"
)

case_pending_recovery() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' > "$dest"
  src=$(mktemp); printf 'new\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  future=$(( $(rm_epoch)+3600 ))
  id=$(tx_begin pending "$future"); tx_stage_file "$id" "$src" "$dest"; tx_apply "$id"
  assert_eq APPLIED_PENDING "$(jq -r .status "$(tx_file "$id")")"
  tx_recover_pending
  assert_eq old "$(cat "$dest")" 'startup recovery stopped respecting its force-rollback contract'
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id")")"
)

case_maintenance_reconcile_deadline() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' > "$dest"

  src=$(mktemp); src2=''; printf 'future\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"; [[ -z $src2 ]] || rm -f "$src2"' EXIT
  future=$(( $(rm_epoch)+3600 ))
  id=$(tx_begin reconcile-future "$future")
  tx_stage_file "$id" "$src" "$dest"
  tx_apply "$id"
  tx_reconcile_pending
  assert_eq future "$(cat "$dest")" 'maintenance reconcile rolled back before deadline'
  assert_eq APPLIED_PENDING "$(jq -r .status "$(tx_file "$id")")" 'future pending transaction was not preserved'

  # Explicit/startup recovery still owns force rollback of an unfinished transaction.
  tx_recover_pending
  assert_eq old "$(cat "$dest")"
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id")")"

  src2=$(mktemp); printf 'expired\n' > "$src2"
  expired=$(( $(rm_epoch)-1 ))
  id2=$(tx_begin reconcile-expired "$expired")
  tx_stage_file "$id2" "$src2" "$dest"
  tx_apply "$id2"
  tx_reconcile_pending
  assert_eq old "$(cat "$dest")" 'expired transaction was not rolled back by maintenance reconcile'
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id2")")"
)

case_kill_window_recovery() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' > "$dest"
  src=$(mktemp); printf 'new\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  id=$(tx_begin kill-window); tx_stage_file "$id" "$src" "$dest"
  staged=$(jq -r '.files[0].staged' "$(tx_file "$id")")
  tx_update "$id" '(.files[0].phase="APPLYING")'
  cp "$staged" "$dest"
  # Simulates SIGKILL after atomic content replacement but before applied_sha256/status update.
  tx_recover_pending
  assert_eq old "$(cat "$dest")"
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id")")"
)

case_external_drift_preserved() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' > "$dest"
  src=$(mktemp); printf 'new\n' > "$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  id=$(tx_begin drift-after-apply); tx_stage_file "$id" "$src" "$dest"; tx_apply "$id"
  printf 'third-party\n' > "$dest"
  set +e; tx_rollback "$id" external-drift >/dev/null 2>&1; rc=$?; set -e
  assert_eq 21 "$rc" 'external drift did not require recovery'
  assert_eq third-party "$(cat "$dest")" 'rollback overwrote third-party change'
  assert_eq NEEDS_RECOVERY "$(jq -r .status "$(tx_file "$id")")"
)

case_boot_guard_rollback_skips_service_restore() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"
  : >"$RM_SYSTEMCTL_LOG"
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init

  dest="$root/etc/relay-manager/demo.conf"; printf 'old\n' >"$dest"
  src=$(mktemp); printf 'new\n' >"$src"; trap 'rm -rf "$root"; rm -f "$src"' EXIT
  id=$(tx_begin boot-guard)
  tx_stage_file "$id" "$src" "$dest"
  tx_update "$id" '.services=[{name:"ssh.socket",was_enabled:true,was_active:true,managed_change:true}]'
  tx_apply "$id"

  tx_rollback "$id" boot-guard-test false
  assert_eq old "$(cat "$dest")" 'boot-guard rollback did not restore files'
  assert_eq ROLLED_BACK "$(jq -r .status "$(tx_file "$id")")"
  if grep -Eq '(^| )(enable|disable|start|stop) ssh\.socket($| )' "$RM_SYSTEMCTL_LOG"; then
    fail 'boot-guard transaction rollback touched SSH service state'
  fi
)

case_conflicting_transaction_blocked() (
  set -Eeuo pipefail
  root=$(new_test_root); trap 'rm -rf "$root"' EXIT
  export RM_ROOT="$root" RM_TEST_MODE=1
  source "$PROJECT_DIR/lib/transaction.sh"
  state_init
  id=$(tx_begin first)
  set +e; tx_begin second >/dev/null 2>&1; rc=$?; set -e
  assert_eq 10 "$rc" 'second transaction was not blocked'
  tx_rollback "$id" cleanup
)

case_commit_and_rollback
case_stale_plan_rejected
case_pending_recovery
case_maintenance_reconcile_deadline
case_kill_window_recovery
case_external_drift_preserved
case_boot_guard_rollback_skips_service_restore
case_conflicting_transaction_blocked
pass 'transaction apply/commit/rollback, boot-guard recovery, deadline-aware reconcile, stale-plan, recovery, drift, conflict tests'
