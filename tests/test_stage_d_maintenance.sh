#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"

mkdir -p "$root/etc"
printf '0123456789abcdef0123456789abcdef\n' >"$root/etc/machine-id"
stage_b_fake_core "$root" v26.3.27
source "$PROJECT_DIR/lib/maintenance.sh"
state_init
state_update_filter '.core_version="v26.3.27"'

RM_MAINT_TX_KEEP=2
RM_MAINT_VERSION_MIN_AGE_SECONDS=0
RM_BACKUP_LIMIT_BYTES=999999999
RM_BACKUP_KEEP_CONFIG=10
RM_BACKUP_MIN_CONFIG=2
RM_BACKUP_KEEP_UPGRADE=1

for n in 1 2 3; do
  backup_create config >/dev/null
done
assert_eq 3 "$(backup_list | jq 'length')" 'backup fixture did not create three restore points'
RM_BACKUP_LIMIT_BYTES=1

mkdir -p "$RM_TX_DIR"
for n in 1 2 3 4; do
  dir="$RM_TX_DIR/terminal-$n"
  mkdir -p "$dir"
  printf '{"status":"COMMITTED","updated_at":"2026-09-%02dT00:00:00Z"}\n' "$n" >"$dir/transaction.json"
  chmod 0600 "$dir/transaction.json"
done
mkdir -p "$RM_TX_DIR/recovery"
printf '{"status":"NEEDS_RECOVERY","updated_at":"2026-09-30T00:00:00Z"}\n' >"$RM_TX_DIR/recovery/transaction.json"
chmod 0600 "$RM_TX_DIR/recovery/transaction.json"

orphan_export="$RM_EXPORT_DIR/node-old/up-old/current"
foreign_export="$RM_EXPORT_DIR/node-foreign/up-foreign/current"
mkdir -p "$orphan_export" "$foreign_export"
printf '{}\n' >"$orphan_export/manifest.json"
printf 'do not delete\n' >"$foreign_export/notes.txt"
chmod 0600 "$orphan_export/manifest.json" "$foreign_export/notes.txt"

evidence_dir="$RM_VAR_DIR/evidence/d4"
mkdir -p "$evidence_dir"
printf '{"result":"pass","upstream_id":"up-old","fingerprint":"abc"}\n' >"$evidence_dir/up-old.json"
printf '{"custom":true}\n' >"$evidence_dir/foreign.json"
chmod 0600 "$evidence_dir/up-old.json" "$evidence_dir/foreign.json"

current_manager="$RM_VERSION_BASE/current-version"
previous_manager="$RM_VERSION_BASE/previous-version"
old_manager="$RM_VERSION_BASE/old-managed"
foreign_manager="$RM_VERSION_BASE/foreign"
mkdir -p "$current_manager" "$previous_manager" "$old_manager" "$foreign_manager" "$(dirname "$RM_MANAGER_CURRENT")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$current_manager/relay-manager.sh"
chmod 0755 "$current_manager/relay-manager.sh"
ln -s "$current_manager" "$RM_MANAGER_CURRENT"
state_update_filter '.previous_manager_path=$p' --arg p "$previous_manager"
mkdir -p "$(dirname "$RM_TRUSTED_RELEASE_KEY")"
printf 'fixture key\n' >"$RM_TRUSTED_RELEASE_KEY"
chmod 0644 "$RM_TRUSTED_RELEASE_KEY"

old_core="$RM_CORE_BASE/v-old-managed"
foreign_core="$RM_CORE_BASE/v-foreign"
mkdir -p "$old_core" "$foreign_core"
printf '#!/usr/bin/env bash\nexit 0\n' >"$old_core/xray"
printf 'foreign\n' >"$foreign_core/keep"
chmod 0755 "$old_core/xray"

update_verify_release_dir() {
  [[ $1 == "$old_manager" ]]
}
xray_core_verify_prepared() {
  [[ $1 == v-old-managed ]]
}

tx_removed=$(maintenance_prune_transactions)
assert_eq 2 "$tx_removed" 'terminal transaction retention did not prune the oldest terminal entries'
[[ -d $RM_TX_DIR/recovery ]] || fail 'terminal pruning deleted NEEDS_RECOVERY transaction'

rc=0
maintenance_prune_safe >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'full maintenance did not pause for NEEDS_RECOVERY transaction'
assert_eq 3 "$(backup_list | jq 'length')" 'paused maintenance modified backups'
[[ -d $old_manager && -d $old_core ]] || fail 'paused maintenance removed versions'
rm -rf -- "$RM_TX_DIR/recovery"

status_before=$(maintenance_status_json)
assert_json "$status_before" '
  .status=="ok" and
  .runtime.persistent_manager_daemon==false and
  .runtime.maintenance_mode=="systemd oneshot" and
  .logging.xray_loglevel=="warning" and
  .logging.xray_access_log=="disabled" and
  .logging.system_journal=="external_not_modified" and
  .policy.terminal_transactions_keep==2
'

result=$(maintenance_prune_safe)
assert_json "$result" '
  .status=="pruned" and
  .removed.terminal_transactions==0 and
  .removed.backups==1 and
  .removed.export_directories==1 and
  .removed.d4_evidence==1 and
  .removed.manager_versions==1 and
  .removed.core_versions==1
'

tx_status=$(maintenance_transaction_counts_json)
assert_json "$tx_status" '.terminal==2 and .pending_recovery==0'

assert_eq 2 "$(backup_list | jq 'length')" 'backup pressure pruning did not protect exactly the configured minimum'
[[ ! -e $orphan_export ]] || fail 'orphan managed export was not pruned'
[[ -f $foreign_export/notes.txt ]] || fail 'unknown export content was deleted'
[[ ! -e $evidence_dir/up-old.json ]] || fail 'orphan D4 evidence was not pruned'
[[ -f $evidence_dir/foreign.json ]] || fail 'unknown evidence was deleted'

[[ -d $current_manager ]] || fail 'current manager version was deleted'
[[ -d $previous_manager ]] || fail 'previous manager version was deleted'
[[ ! -e $old_manager ]] || fail 'verified inactive manager version was not pruned'
[[ -d $foreign_manager ]] || fail 'unverified manager version was deleted'

[[ -d "$RM_CORE_BASE/v26.3.27" ]] || fail 'current core version was deleted'
[[ ! -e $old_core ]] || fail 'verified inactive core version was not pruned'
[[ -d $foreign_core ]] || fail 'unverified core version was deleted'

status_after=$(maintenance_status_json)
assert_json "$status_after" '
  .usage.transactions.counts.terminal==2 and
  .usage.transactions.counts.pending_recovery==0 and
  .usage.backups.count==2
'

pass 'Stage D maintenance bounds owned growth without deleting recovery state, active versions or unknown content'
