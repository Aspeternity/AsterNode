#!/usr/bin/env bash
set -Eeuo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
BASE_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
source "$BASE_DIR/lib/system.sh"
source "$BASE_DIR/lib/node.sh"
source "$BASE_DIR/lib/firewall.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/fail2ban.sh"
source "$BASE_DIR/lib/backup.sh"
source "$BASE_DIR/lib/export.sh"
source "$BASE_DIR/lib/update.sh"
source "$BASE_DIR/lib/target.sh"
source "$BASE_DIR/lib/remove.sh"

mutation_guard() {
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  rm_require_root || return $?
  rm_tty_available || { rm_error '首版不支持无交互批量修改；未检测到 TTY，停止。'; return "$RM_RC_PRECONDITION"; }
  tx_recover_pending || { local rc=$?; [[ $rc == $RM_RC_RECOVERY_INCOMPLETE ]] && return "$rc"; }
}

status_cmd() {
  local env state='null' tx='[]'
  env=$(system_probe_fast)
  if [[ -f $(rm_path /etc/relay-manager/state.json) ]]; then
    source "$BASE_DIR/lib/state.sh"
    if state_validate; then state=$(jq '{schema_version,manager_version,core_version,config_revision,nodes:[.nodes[]|{node_id,name,enabled,listen_port,access_mode}],upstreams:[.upstreams[]|{upstream_id,name,node_id,enabled,source_addresses,rotation}],temporary_opens}' "$RM_STATE_FILE"); else state=$(jq -n '{status:"invalid"}'); fi
    [[ -d $RM_VAR_DIR/transactions ]] && tx=$(tx_status_json)
  fi
  jq -n --arg version "$RM_MANAGER_VERSION" --argjson env "$env" --argjson state "$state" --argjson transactions "$tx" '{manager_version:$version,environment:$env,managed_state:$state,transactions:$transactions}'
}

quick_deploy() {
  mutation_guard || return $?
  rm_info '快速部署会依次调用核心安装、节点、线路机、可选 UFW；不会维护第二套实现。'
  local env; env=$(system_probe_fast); printf '%s\n' "$env" | jq '{support:.support,cpu:.cpu,memory:.memory,disk:.disk,package_manager:.package_manager,firewall:.firewall,external_processes:.external_processes}'
  jq -e '.support.os_supported==true and .support.arch.supported==true and .support.systemd==true' <<<"$env" >/dev/null || { rm_error '当前环境未达到首版自动部署支持条件。'; return "$RM_RC_PRECONDITION"; }
  jq -e '.package_manager.locked==false' <<<"$env" >/dev/null || return "$RM_RC_PRECONDITION"
  xray_check_external_conflict || return $?
  if ! xray_core_installed "$(xray_default_version)"; then rm_confirm "安装已验证 Xray $(xray_default_version)?" || return "$RM_RC_CANCEL"; xray_core_install; fi
  xray_service_install
  printf '可选 REALITY Target 探测（只读，本次结果不自动选择）\n' >&2
  if rm_confirm '现在探测版本内置候选?'; then target_probe_candidates | jq .; fi
  local tmpdir nodepart upname source spec answer
  tmpdir=$(rm_safe_tmpdir); nodepart="$tmpdir/node.json"; spec="$tmpdir/spec.json"
  "$RM_PROTOCOL_VR" collect >"$nodepart"
  rm_read_tty upname '线路机名称: '; rm_valid_name "$upname" || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  rm_read_tty source '线路机实际出口 IP/CIDR（白名单模式必填）: '
  jq -n --slurpfile n "$nodepart" --arg upname "$upname" --arg source "$source" '{node:$n[0],upstreams:[{name:$upname,source_addresses:(if $source=="" then [] else [$source] end)}]}' >"$spec"
  printf '将应用以下非秘密配置：\n' >&2; jq '{node:.node,upstreams:[.upstreams[]|{name,source_addresses}]}' "$spec"
  rm_confirm '确认创建节点?' || { rm -rf "$tmpdir"; return "$RM_RC_CANCEL"; }
  local created nid upid; created=$(node_create_or_replace_spec "$spec" create) || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  nid=$(jq -r .node_id <<<"$created"); upid=$(jq -r '.upstream_ids[0]' <<<"$created")
  if [[ -n $source && $(jq -r '.node.access_mode' "$spec") == whitelist ]]; then
    local fws; fws=$(fw_status_json); if jq -e '.installed and .active and (.complex_environment|not)' <<<"$fws" >/dev/null; then
      rm_info '节点已创建。现在应用 UFW 来源白名单。'; fw_apply_whitelist "$nid" "$(jq -r '.node.listen_port' "$spec")" "$source" || rm_warn '节点可用性未回滚，但 UFW 白名单未验证/未应用；请立即检查 firewall 状态。'
    else rm_warn '未自动实施本机来源限制；状态为未实施/未验证。'; fi
  fi
  export_upstream "$upid" current false
  rm -rf "$tmpdir"
}

node_cmd() {
  local sub=${1:-list}; shift || true
  case "$sub" in
    list) [[ -f $RM_STATE_FILE ]] || { printf '[]\n'; return; }; jq '.nodes' "$RM_STATE_FILE";;
    create) mutation_guard; [[ -f ${1:-} ]] || return "$RM_RC_PRECONDITION"; node_create_or_replace_spec "$1" create;;
    replace) mutation_guard; [[ -f ${1:-} ]] || return "$RM_RC_PRECONDITION"; node_create_or_replace_spec "$1" upsert;;
    enable) mutation_guard; node_set_enabled "$1" true;;
    disable) mutation_guard; node_set_enabled "$1" false;;
    delete) mutation_guard; fw_remove_node_rules "$1" || true; node_delete "$1";;
    *) return "$RM_RC_PRECONDITION";;
  esac
}

upstream_cmd() {
  local sub=${1:-list}; shift || true
  case "$sub" in
    list) [[ -f $RM_STATE_FILE ]] || { printf '[]\n'; return; }; state_validate || return "$RM_RC_PRECONDITION"; jq '.upstreams' "$RM_STATE_FILE";;
    add) mutation_guard; upstream_add_from_json "$1" "$2";;
    delete) mutation_guard; export_invalidate_upstream "$1"; upstream_delete "$1";;
    rotate-prepare) mutation_guard; upstream_rotation_prepare "$1" "${2:-86400}";;
    rotate-commit) mutation_guard; upstream_rotation_commit "$1";;
    rotate-cancel) mutation_guard; upstream_rotation_cancel "$1";;
    *) return "$RM_RC_PRECONDITION";;
  esac
}

ssh_cmd() {
  local sub=${1:-status}; shift || true
  case "$sub" in
    status) ssh_detect_json "${1:-root}" "${2:-127.0.0.1}";;
    add-key) mutation_guard; ssh_add_public_key "$1" "$2";;
    migrate-port) mutation_guard; ssh_begin_port_migration "$1";;
    remove-old-port) mutation_guard; ssh_begin_remove_old_port "$1";;
    mark-key-verified) mutation_guard; ssh_mark_key_verified "$1";;
    disable-password) mutation_guard; ssh_begin_disable_password "$1";;
    verify-sudo) mutation_guard; ssh_record_sudo_verified "$1";;
    root-publickey-only) mutation_guard; ssh_begin_root_policy publickey-only root;;
    root-disable) mutation_guard; ssh_begin_root_policy disable "$1";;
    confirm) mutation_guard; ssh_confirm_pending "${1:-}";;
    rollback-pending) rm_require_root; ssh_rollback_pending;;
    *) return "$RM_RC_PRECONDITION";;
  esac
}

firewall_cmd() {
  local sub=${1:-status}; shift || true
  case "$sub" in
    status) fw_status_json;;
    apply) mutation_guard; local nid=$1 node port; shift; node=$(state_get_node "$nid"); port=$(jq -r .listen_port <<<"$node"); fw_apply_whitelist "$nid" "$port" "$@";;
    remove-node) mutation_guard; fw_remove_node_rules "$1";;
    temp-open) mutation_guard; fw_temp_open "$1" "${2:-10}";;
    expire-temp) rm_require_root; fw_expire_temp "$1";;
    reconcile-expired) rm_require_root; fw_reconcile_expired;;
    *) return "$RM_RC_PRECONDITION";;
  esac
}

fail2ban_cmd() {
  local sub=${1:-status}; shift || true
  case "$sub" in status) f2b_status_json;; install) mutation_guard; f2b_install_packages false;; apply) mutation_guard; f2b_apply_ssh_jail;; banned) f2b_banned_json;; unban) mutation_guard; f2b_unban "$1";; *) return "$RM_RC_PRECONDITION";; esac
}

backup_cmd() { local sub=${1:-list}; shift || true; case "$sub" in list) backup_list;; create) mutation_guard; backup_create "${1:-config}";; restore) mutation_guard; backup_restore_local "$1";; restore-nodes) mutation_guard; backup_restore_nodes_only "$1";; *) return "$RM_RC_PRECONDITION";; esac; }

update_cmd() { local sub=${1:-status}; shift || true; case "$sub" in core) mutation_guard; update_core_to "$1";; manager-package) mutation_guard; update_install_manager_package "$1" "${2:-}";; rollback-manager) mutation_guard; update_manager_rollback;; status) jq '{default_core_version,core:.core.xray,client_profiles}' "$RM_COMPAT_FILE";; *) return "$RM_RC_PRECONDITION";; esac; }

remove_cmd() { local sub=${1:-manager}; shift || true; case "$sub" in manager) mutation_guard; rm_confirm '确认删除受管节点与管理器？SSH/UFW/Fail2ban 安全设置默认保留。' || return "$RM_RC_CANCEL"; remove_all_nodes_and_manager false false;; backups) mutation_guard; remove_backups_only;; exports) mutation_guard; remove_exports_only;; *) return "$RM_RC_PRECONDITION";; esac; }

interactive_menu() {
  # ENV-01: entering the manager is read-only. Mutating menu actions invoke their own guard.
  while true; do
    cat >&2 <<'MENU'
========================================
 Relay Manager
========================================
1. 快速部署
2. SSH 安全
3. 安全组件
4. 节点
5. 线路机
6. 导出
7. 诊断
8. 更新 / 回退
9. 备份 / 恢复
10. 卸载
0. 退出
MENU
    local c; rm_read_tty c '请选择: '
    case "$c" in
      1) quick_deploy;;
      2) ssh_detect_json root 127.0.0.1 | jq .; printf 'SSH 修改请使用 help 中的明确子命令，以便逐步验证。\n' >&2;;
      3) printf 'UFW: '; fw_status_json | jq .; printf 'Fail2ban: '; f2b_status_json | jq .;;
      4) node_cmd list | jq .;; 5) upstream_cmd list | jq .;;
      6) local up; rm_read_tty up 'upstream_id: '; export_upstream "$up" current false | jq .;;
      7) "$BASE_DIR/diagnostics.sh" doctor | jq .;;
      8) update_cmd status | jq .;; 9) backup_cmd list | jq .;;
      10) remove_cmd manager; return;; 0) return 0;; *) printf '无效选择\n' >&2;;
    esac
  done
}

help_cmd() {
  cat <<'HELP'
Relay Manager CLI
  relay-manager                      交互菜单
  relay-manager env                  只读环境体检
  relay-manager status               只读状态
  relay-manager quick-deploy         交互快速部署
  relay-manager doctor               D1-D4 分层诊断
  relay-manager target probe|list    Target 探测
  relay-manager core install         安装兼容矩阵固定 Xray
  relay-manager node list|create FILE|replace FILE|enable ID|disable ID|delete ID
  relay-manager upstream list|add NODE FILE|delete ID|rotate-prepare ID [SEC]|rotate-commit ID|rotate-cancel ID
  relay-manager export UPSTREAM [current|pending] [--show]
  relay-manager firewall status|apply NODE SOURCE...|remove-node NODE|temp-open NODE [MIN]|expire-temp NODE
  relay-manager ssh status [USER]|add-key USER FILE|migrate-port PORT|remove-old-port PORT
                    mark-key-verified USER|disable-password USER|verify-sudo USER
                    root-publickey-only|root-disable ADMIN_USER|confirm [TX]|rollback-pending
  relay-manager fail2ban status|install|apply|banned|unban IP
  relay-manager backup list|create [config|upgrade]|restore ID|restore-nodes ID
  relay-manager update status|core VERSION|manager-package FILE [SHA256]|rollback-manager
  relay-manager remove manager|backups|exports

修改命令要求 root + TTY。退出码：0 成功，2 取消，10 输入/前置条件，20 应用失败已恢复，
21 恢复不完整，30 网络/下载失败。完整凭据仅在 export ... --show 时主动显示。
HELP
}

cmd=${1:-}; [[ $# -gt 0 ]] && shift || true
case "$cmd" in
  '') interactive_menu;; env) system_probe_fast "${1:-root}" "${2:-127.0.0.1}";; status) status_cmd;; quick-deploy) quick_deploy;; doctor) "$BASE_DIR/diagnostics.sh" doctor;;
  target) sub=${1:-list}; shift || true; case "$sub" in list) target_probe_candidates;; probe) target_probe "$1" "$2";; *) exit 10;; esac;;
  core) sub=${1:-}; shift || true; case "$sub" in install) mutation_guard; xray_core_install "${1:-$(xray_default_version)}"; xray_service_install;; *) exit 10;; esac;;
  node) node_cmd "$@";; upstream) upstream_cmd "$@";; export) state_init >/dev/null; show=false; [[ ${3:-} == --show ]] && show=true; export_upstream "$1" "${2:-current}" "$show";;
  firewall) firewall_cmd "$@";; ssh) ssh_cmd "$@";; fail2ban) fail2ban_cmd "$@";; backup|restore) backup_cmd "$@";; update) update_cmd "$@";; remove|uninstall) remove_cmd "$@";;
  help|-h|--help) help_cmd;; *) help_cmd >&2; exit "$RM_RC_PRECONDITION";;
esac
