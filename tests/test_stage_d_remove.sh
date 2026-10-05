#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1 RM_SYSTEMCTL_LOG="$root/systemctl.log"

mkdir -p "$root/etc"
printf '0123456789abcdef0123456789abcdef\n' >"$root/etc/machine-id"
stage_b_fake_core "$root" v26.3.27
source "$PROJECT_DIR/lib/remove.sh"
state_init
state_update_filter '.core_version="v26.3.27"'

own_file() {
  local logical=$1 content=$2 path
  path=$(rm_path "$logical")
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  chmod 0644 "$path"
  state_add_owned_file "$logical" "$(rm_sha256_file "$path")"
}

state_add_owned_file /etc/systemd/system/relay-manager-xray.service "$(rm_sha256_file "$RM_XRAY_SERVICE_FILE")"
mkdir -p "$(dirname "$RM_XRAY_CONFIG")"
printf '{"log":{"loglevel":"warning"}}\n' >"$RM_XRAY_CONFIG"
chmod 0640 "$RM_XRAY_CONFIG"
state_add_owned_file /etc/relay-manager-xray/config.json "$(rm_sha256_file "$RM_XRAY_CONFIG")"

own_file /etc/systemd/system/relay-manager-maintenance.service 'managed maintenance service'
own_file /etc/systemd/system/relay-manager-maintenance.timer 'managed maintenance timer'
own_file /etc/systemd/system/relay-manager-firewall-guard.service 'managed firewall guard'
own_file /etc/systemd/system/relay-manager-ssh-rollback.service 'managed ssh rollback service'
own_file /etc/systemd/system/relay-manager-ssh-rollback.timer 'managed ssh rollback timer'
own_file /etc/systemd/system/relay-manager-ssh-boot-guard.service 'managed ssh boot guard'
own_file /etc/systemd/system/ssh.service.d/relay-manager-guard.conf 'managed ssh guard'
own_file /etc/systemd/system/relay-manager-temp-node-fw.service 'managed temporary access service'
own_file /etc/systemd/system/relay-manager-temp-node-fw.timer 'managed temporary access timer'
state_add_owned_service relay-manager-temp-node-fw.service
state_add_owned_service relay-manager-temp-node-fw.timer

own_file /etc/ssh/sshd_config.d/00-relay-manager.conf 'PasswordAuthentication no'
own_file /etc/fail2ban/jail.d/relay-manager-sshd.local '[relay-manager-sshd]'

mkdir -p "$(dirname "$RM_TRUSTED_RELEASE_KEY")"
printf 'preserved trust anchor\n' >"$RM_TRUSTED_RELEASE_KEY"
chmod 0644 "$RM_TRUSTED_RELEASE_KEY"

current_version="$RM_VERSION_BASE/0.2.0-dev"
previous_version="$RM_VERSION_BASE/0.1.0-dev"
foreign_version="$RM_VERSION_BASE/foreign-version"
mkdir -p "$current_version" "$previous_version" "$foreign_version" "$(dirname "$RM_BIN_LINK")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$current_version/relay-manager.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$previous_version/relay-manager.sh"
chmod 0755 "$current_version/relay-manager.sh" "$previous_version/relay-manager.sh"
printf 'foreign\n' >"$foreign_version/keep.txt"
ln -s "$current_version" "$RM_MANAGER_CURRENT"
ln -s "$RM_MANAGER_CURRENT/relay-manager.sh" "$RM_BIN_LINK"
state_update_filter '.previous_manager_path=$p' --arg p "$previous_version"

foreign_core="$RM_CORE_BASE/v99-foreign"
mkdir -p "$foreign_core"
printf 'foreign core\n' >"$foreign_core/keep.txt"

mkdir -p "$RM_EXPORT_DIR/example" "$RM_VAR_DIR/evidence/d4" "$RM_TX_DIR/committed" "$RM_TX_SNAPSHOT_DIR/old"
printf 'export\n' >"$RM_EXPORT_DIR/example/keep.txt"
printf 'evidence\n' >"$RM_VAR_DIR/evidence/d4/keep.txt"
printf 'snapshot\n' >"$RM_TX_SNAPSHOT_DIR/old/keep.txt"

printf 'external drift\n' >"$RM_SSH_SERVICE_GUARD_DROPIN"
rc=0
remove_all_nodes_and_manager false false >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'critical SSH guard drift did not stop uninstall'
[[ -L $RM_BIN_LINK ]] || fail 'failed preflight partially removed manager command'
[[ -f $RM_STATE_FILE ]] || fail 'failed preflight removed state'
[[ ! -e $RM_BACKUP_DIR ]] || fail 'failed preflight created a recovery backup'

printf 'managed ssh guard\n' >"$RM_SSH_SERVICE_GUARD_DROPIN"
: >"$RM_SYSTEMCTL_LOG"
result=$(remove_all_nodes_and_manager false false)
assert_json "$result" '
  .status=="manager_and_nodes_removed" and
  (.recovery_backup_id|type=="string" and length>0) and
  .backups_removed==false and .exports_removed==false and
  (.security_preserved|length)>=4
'
recovery=$(jq -r .recovery_backup_id <<<"$result")
backup_verify "$recovery"

[[ ! -e $RM_STATE_FILE ]] || fail 'uninstall left stale state.json'
[[ ! -e $RM_BIN_LINK && ! -e $RM_MANAGER_CURRENT ]] || fail 'managed manager links were not removed'
[[ ! -e $current_version && ! -e $previous_version ]] || fail 'current/previous managed manager versions were not removed'
[[ -f $foreign_version/keep.txt ]] || fail 'unproven manager version was deleted'

[[ ! -e "$RM_CORE_BASE/v26.3.27" && ! -e $RM_CORE_CURRENT ]] || fail 'current managed core was not removed'
[[ -f $foreign_core/keep.txt ]] || fail 'unproven core version was deleted'

for path in   "$RM_XRAY_SERVICE_FILE" "$RM_MAINT_SERVICE_FILE" "$RM_MAINT_TIMER_FILE" "$RM_FW_GUARD_SERVICE_FILE"   "$RM_SSH_PROTECT_SERVICE" "$RM_SSH_PROTECT_TIMER" "$RM_SSH_BOOT_GUARD_SERVICE" "$RM_SSH_SERVICE_GUARD_DROPIN"; do
  [[ ! -e $path && ! -L $path ]] || fail "managed runtime helper was not removed: $path"
done
[[ ! -e "$(rm_path /etc/systemd/system/relay-manager-temp-node-fw.service)" ]] ||
  fail 'owned temporary access service unit was not removed'
[[ ! -e "$(rm_path /etc/systemd/system/relay-manager-temp-node-fw.timer)" ]] ||
  fail 'owned temporary access timer unit was not removed'
[[ ! -e $RM_XRAY_CONFIG ]] || fail 'owned Xray config was not removed'

[[ -f $RM_SSH_DROPIN ]] || fail 'SSH security policy was removed'
[[ -f $(rm_path /etc/fail2ban/jail.d/relay-manager-sshd.local) ]] || fail 'Fail2ban policy was removed'
[[ -f $RM_TRUSTED_RELEASE_KEY ]] || fail 'trusted release key was removed'

[[ -f $RM_EXPORT_DIR/example/keep.txt ]] || fail 'exports were not preserved by default'
[[ -d $RM_BACKUP_DIR && -f $RM_BACKUP_DIR/$recovery/manifest.json ]] || fail 'recovery backup was not preserved'
[[ ! -e $RM_VAR_DIR/evidence && ! -e $RM_TX_DIR && ! -e $RM_TX_SNAPSHOT_DIR ]] || fail 'runtime transaction/evidence directories were not removed'

grep -Fq 'disable --now relay-manager-xray.service' "$RM_SYSTEMCTL_LOG" || fail 'managed Xray service was not disabled'
grep -Fq 'disable --now relay-manager-maintenance.timer' "$RM_SYSTEMCTL_LOG" || fail 'maintenance timer was not disabled'
grep -Fq 'disable --now relay-manager-ssh-rollback.timer' "$RM_SYSTEMCTL_LOG" || fail 'SSH rollback timer was not disabled'
grep -Fq 'disable --now relay-manager-temp-node-fw.timer' "$RM_SYSTEMCTL_LOG" ||
  fail 'owned temporary access timer was not disabled during uninstall'
grep -Fq 'stop relay-manager-temp-node-fw.service' "$RM_SYSTEMCTL_LOG" ||
  fail 'owned temporary access service was not stopped during uninstall'

jq -e --arg foreign_manager "$foreign_version" --arg foreign_core "$foreign_core" '
  (.preserved_paths|index($foreign_manager))!=null and
  (.preserved_paths|index($foreign_core))!=null
' <<<"$result" >/dev/null || fail 'unproven version paths were not reported as preserved'

remove_exports_only
[[ ! -e $RM_EXPORT_DIR ]] || fail 'explicit export removal left the export directory'
remove_backups_only
[[ ! -e $RM_BACKUP_DIR ]] || fail 'explicit backup removal left the backup directory'

pass 'Stage D removal is ownership-scoped, removes owned temporary units, recovery-backed and preserves system security by default'
