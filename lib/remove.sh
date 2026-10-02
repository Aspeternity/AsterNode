#!/usr/bin/env bash
# Ownership-scoped removal. Security settings are preserved by default.
# shellcheck source=lib/export.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/export.sh"
# shellcheck source=lib/firewall.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/firewall.sh"

remove_all_nodes_and_manager() {
  local purge_backups=${1:-false} purge_exports=${2:-false}
  rm_require_root || return $?
  state_init >/dev/null
  if ssh_pending_tx_id >/dev/null 2>&1; then rm_error '存在待确认 SSH 事务；请先 confirm 或 rollback-pending，再卸载。'; return "$RM_RC_PRECONDITION"; fi
  local nid
  while IFS= read -r nid; do [[ -n $nid ]] || continue; fw_expire_temp "$nid" || return $?; fw_remove_node_rules "$nid" || return $?; done < <(jq -r '.nodes[].node_id' "$RM_STATE_FILE")
  rm_systemctl disable --now "$RM_XRAY_SERVICE" || true
  if [[ ${RM_TEST_MODE} != 1 ]]; then systemctl daemon-reload || true; fi
  # Remove only Relay Manager owned runtime/service/core files. SSH/UFW/Fail2ban policy is intentionally preserved.
  rm -f -- "$RM_XRAY_CONFIG" "$RM_XRAY_SERVICE_FILE"
  rm -rf -- "$RM_CORE_BASE"
  [[ $purge_exports == true ]] && rm -rf -- "$RM_VAR_DIR/exports"
  [[ $purge_backups == true ]] && rm -rf -- "$RM_VAR_DIR/backups"
  local keepdir; keepdir=$(rm_safe_tmpdir)
  cp -f "$RM_STATE_FILE" "$keepdir/final-state.json" 2>/dev/null || true
  # Manager installation paths are exact, never fuzzy-matched.
  rm -f -- "$(rm_path /usr/local/bin/relay-manager)"
  rm -rf -- "$(rm_path /usr/local/lib/relay-manager/versions)" "$(rm_path /usr/local/lib/relay-manager/current)"
  jq -n --arg state_backup "$keepdir/final-state.json" --argjson backups_removed "$purge_backups" --argjson exports_removed "$purge_exports" '{status:"manager_and_nodes_removed",security_preserved:["SSH settings/keys","UFW service/default policy","Fail2ban installation/config"],managed_ufw_rules_removed:true,backups_removed:$backups_removed,exports_removed:$exports_removed,note:"状态副本仅留在当前运行时临时目录用于本次恢复排查；重启后可能消失。",temporary_state_copy:$state_backup}'
}

remove_backups_only() { backup_init; rm -rf -- "$RM_BACKUP_DIR"/*; }
remove_exports_only() { rm -rf -- "$RM_EXPORT_DIR"/* 2>/dev/null || true; }
