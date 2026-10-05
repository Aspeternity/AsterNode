#!/usr/bin/env bash
# Ownership-scoped removal. Security settings are preserved by default.
# shellcheck source=lib/export.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/export.sh"
# shellcheck source=lib/firewall.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/firewall.sh"
# shellcheck source=lib/ssh.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ssh.sh"
# shellcheck source=lib/update.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/update.sh"

REMOVE_PRESERVED_PATHS=()
REMOVE_CURRENT_MANAGER_PATH=''
REMOVE_PREVIOUS_MANAGER_PATH=''
REMOVE_CURRENT_CORE_PATH=''

remove_record_preserved() {
  local path=$1 reason=${2:-'ownership not proven'}
  REMOVE_PRESERVED_PATHS+=("$path")
  rm_warn "保留未能证明可安全删除的路径: $path ($reason)"
}

remove_logical_path() {
  local path=$1 base
  [[ $path == /* ]] || return "$RM_RC_PRECONDITION"
  if [[ -n ${RM_ROOT} ]]; then
    base=${RM_ROOT%/}
    [[ $path == "$base"/* ]] || return "$RM_RC_PRECONDITION"
    printf '%s\n' "${path#"$base"}"
  else
    printf '%s\n' "$path"
  fi
}

remove_owned_sha() {
  local logical=$1
  jq -r --arg path "$logical" '[.owned_files[]? | select(.path==$path) | .sha256][0] // empty' "$RM_STATE_FILE"
}

remove_owned_file_matches() {
  local path=$1 logical expected
  [[ ! -e $path && ! -L $path ]] && return 0
  [[ -f $path && ! -L $path ]] || return 1
  logical=$(remove_logical_path "$path") || return 1
  expected=$(remove_owned_sha "$logical")
  [[ -n $expected && $expected =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ $(rm_sha256_file "$path") == "$expected" ]]
}

remove_critical_file_preflight() {
  local path=$1
  [[ ! -e $path && ! -L $path ]] && return 0
  remove_owned_file_matches "$path" || {
    rm_error "关键受管文件已漂移或缺少所有权记录，拒绝卸载: $path"
    return "$RM_RC_PRECONDITION"
  }
}

remove_critical_files_preflight() {
  local path
  local -a paths=(
    "$RM_XRAY_SERVICE_FILE"
    "$RM_MAINT_SERVICE_FILE"
    "$RM_MAINT_TIMER_FILE"
    "$RM_FW_GUARD_SERVICE_FILE"
    "$RM_SSH_PROTECT_SERVICE"
    "$RM_SSH_PROTECT_TIMER"
    "$RM_SSH_BOOT_GUARD_SERVICE"
    "$RM_SSH_SOCKET_GUARD_DROPIN"
    "$RM_SSH_SERVICE_GUARD_DROPIN"
    "$RM_SSHD_SERVICE_GUARD_DROPIN"
  )
  for path in "${paths[@]}"; do
    remove_critical_file_preflight "$path" || return $?
  done
}

remove_manager_links_preflight() {
  REMOVE_CURRENT_MANAGER_PATH=''
  REMOVE_PREVIOUS_MANAGER_PATH=''

  local resolved literal previous
  if [[ -e $RM_MANAGER_CURRENT || -L $RM_MANAGER_CURRENT ]]; then
    [[ -L $RM_MANAGER_CURRENT ]] || {
      rm_error '管理器 current 路径不是受管符号链接，拒绝卸载'
      return "$RM_RC_PRECONDITION"
    }
    resolved=$(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true)
    [[ -n $resolved && $(dirname "$resolved") == "$RM_VERSION_BASE" && -d $resolved && ! -L $resolved ]] || {
      rm_error '管理器 current 链接不指向直接受管版本目录，拒绝卸载'
      return "$RM_RC_PRECONDITION"
    }
    REMOVE_CURRENT_MANAGER_PATH=$resolved
  fi

  if [[ -e $RM_BIN_LINK || -L $RM_BIN_LINK ]]; then
    [[ -L $RM_BIN_LINK && -n $REMOVE_CURRENT_MANAGER_PATH ]] || {
      rm_error 'relay-manager 命令路径不是当前受管链接，拒绝卸载'
      return "$RM_RC_PRECONDITION"
    }
    literal=$(readlink "$RM_BIN_LINK" 2>/dev/null || true)
    resolved=$(readlink -f "$RM_BIN_LINK" 2>/dev/null || true)
    [[ $literal == "$RM_MANAGER_CURRENT/relay-manager.sh" &&
       $resolved == "$REMOVE_CURRENT_MANAGER_PATH/relay-manager.sh" ]] || {
      rm_error 'relay-manager 命令链接与 current 不一致，拒绝卸载'
      return "$RM_RC_PRECONDITION"
    }
  fi

  previous=$(jq -r '.previous_manager_path//empty' "$RM_STATE_FILE")
  if [[ -n $previous ]]; then
    [[ -d $previous && ! -L $previous && $(dirname "$previous") == "$RM_VERSION_BASE" ]] || {
      rm_error '状态中的上一管理器版本路径不属于直接受管版本目录'
      return "$RM_RC_PRECONDITION"
    }
    REMOVE_PREVIOUS_MANAGER_PATH=$previous
  fi
}

remove_core_preflight() {
  REMOVE_CURRENT_CORE_PATH=''
  local resolved version
  version=$(jq -r '.core_version//empty' "$RM_STATE_FILE")
  if [[ -e $RM_CORE_CURRENT || -L $RM_CORE_CURRENT ]]; then
    [[ -L $RM_CORE_CURRENT && -n $version ]] || {
      rm_error '核心 current 路径与状态不一致，拒绝卸载'
      return "$RM_RC_PRECONDITION"
    }
    resolved=$(readlink -f "$RM_CORE_CURRENT" 2>/dev/null || true)
    [[ -n $resolved && $(dirname "$resolved") == "$RM_CORE_BASE" &&
       $(basename "$resolved") == "$version" && -d $resolved && ! -L $resolved ]] || {
      rm_error '核心 current 链接不属于状态记录的直接受管版本'
      return "$RM_RC_PRECONDITION"
    }
    REMOVE_CURRENT_CORE_PATH=$resolved
  elif [[ -n $version ]]; then
    rm_error '状态记录了核心版本但 current 链接缺失，拒绝静默卸载'
    return "$RM_RC_PRECONDITION"
  fi
}

remove_preflight() {
  tx_has_conflict && {
    rm_error '存在未完成事务，必须先恢复/确认后再卸载。'
    return "$RM_RC_PRECONDITION"
  }
  if ssh_pending_tx_id >/dev/null 2>&1; then
    rm_error '存在待确认 SSH 事务；请先 confirm 或 rollback-pending，再卸载。'
    return "$RM_RC_PRECONDITION"
  fi
  remove_critical_files_preflight || return $?
  remove_manager_links_preflight || return $?
  remove_core_preflight || return $?
}

remove_delete_critical_file() {
  local path=$1
  [[ ! -e $path && ! -L $path ]] && return 0
  remove_owned_file_matches "$path" || {
    rm_error "关键文件在卸载过程中发生变化，停止继续删除: $path"
    return "$RM_RC_RECOVERY_INCOMPLETE"
  }
  rm -f -- "$path"
}

remove_owned_file_if_unchanged() {
  local path=$1
  [[ ! -e $path && ! -L $path ]] && return 0
  if remove_owned_file_matches "$path"; then
    rm -f -- "$path"
  else
    remove_record_preserved "$path" '文件漂移或无所有权记录'
  fi
}

remove_dynamic_temp_units() {
  local name logical path

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    case "$name" in
      relay-manager-temp-*.timer)
        rm_systemctl disable --now "$name" >/dev/null 2>&1 || true
        ;;
      relay-manager-temp-*.service)
        rm_systemctl stop "$name" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(jq -r '
    .owned_services[]?
    | select(test("^relay-manager-temp-[A-Za-z0-9_.-]+\\.(service|timer)$"))
  ' "$RM_STATE_FILE")

  while IFS= read -r logical; do
    [[ -n $logical ]] || continue
    path=$(rm_path "$logical")
    remove_owned_file_if_unchanged "$path" || return $?
  done < <(jq -r '
    .owned_files[]?.path
    | select(test("^/etc/systemd/system/relay-manager-temp-[^/]+\\.(service|timer)$"))
  ' "$RM_STATE_FILE")

  rm_systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_disable_runtime_units() {
  rm_systemctl disable --now "$RM_MAINT_TIMER" >/dev/null 2>&1 || true
  rm_systemctl stop "$RM_MAINT_SERVICE" >/dev/null 2>&1 || true
  rm_systemctl stop "$RM_FW_GUARD_SERVICE" >/dev/null 2>&1 || true
  rm_systemctl disable --now "$RM_XRAY_SERVICE" >/dev/null 2>&1 || true
  rm_systemctl disable --now relay-manager-ssh-rollback.timer >/dev/null 2>&1 || true
  rm_systemctl stop relay-manager-ssh-rollback.service >/dev/null 2>&1 || true
  rm_systemctl stop relay-manager-ssh-boot-guard.service >/dev/null 2>&1 || true
}

remove_delete_runtime_unit_files() {
  local path
  local -a paths=(
    "$RM_XRAY_SERVICE_FILE"
    "$RM_MAINT_SERVICE_FILE"
    "$RM_MAINT_TIMER_FILE"
    "$RM_FW_GUARD_SERVICE_FILE"
    "$RM_SSH_PROTECT_SERVICE"
    "$RM_SSH_PROTECT_TIMER"
    "$RM_SSH_BOOT_GUARD_SERVICE"
    "$RM_SSH_SOCKET_GUARD_DROPIN"
    "$RM_SSH_SERVICE_GUARD_DROPIN"
    "$RM_SSHD_SERVICE_GUARD_DROPIN"
  )
  for path in "${paths[@]}"; do remove_delete_critical_file "$path" || return $?; done
  rm_systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_managed_core_files() {
  local d version
  if [[ -n $REMOVE_CURRENT_CORE_PATH ]]; then
    [[ -L $RM_CORE_CURRENT &&
       $(readlink -f "$RM_CORE_CURRENT" 2>/dev/null || true) == "$REMOVE_CURRENT_CORE_PATH" ]] || {
      rm_error '核心 current 链接在卸载过程中发生变化'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    }
    rm -f -- "$RM_CORE_CURRENT"
    rm -rf -- "$REMOVE_CURRENT_CORE_PATH"
  fi

  if [[ -d $RM_CORE_BASE && ! -L $RM_CORE_BASE ]]; then
    for d in "$RM_CORE_BASE"/*; do
      [[ -d $d && ! -L $d ]] || continue
      [[ $d == "$REMOVE_CURRENT_CORE_PATH" ]] && continue
      version=${d##*/}
      if xray_core_verify_prepared "$version" >/dev/null 2>&1; then
        rm -rf -- "$d"
      else
        remove_record_preserved "$d" '额外核心版本无法由当前兼容矩阵证明所有权'
      fi
    done
    rmdir "$RM_CORE_BASE" 2>/dev/null || true
  fi
}

remove_manager_version_dir() {
  local dir=$1
  [[ -n $dir ]] || return 0
  [[ -d $dir && ! -L $dir && $(dirname "$dir") == "$RM_VERSION_BASE" ]] || return "$RM_RC_PRECONDITION"
  rm -rf -- "$dir"
}

remove_managed_manager_files() {
  local d
  if [[ -e $RM_BIN_LINK || -L $RM_BIN_LINK ]]; then
    [[ -L $RM_BIN_LINK && -n $REMOVE_CURRENT_MANAGER_PATH &&
       $(readlink "$RM_BIN_LINK" 2>/dev/null || true) == "$RM_MANAGER_CURRENT/relay-manager.sh" &&
       $(readlink -f "$RM_BIN_LINK" 2>/dev/null || true) == "$REMOVE_CURRENT_MANAGER_PATH/relay-manager.sh" ]] || {
      rm_error 'relay-manager 命令链接在卸载过程中发生变化'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    }
    rm -f -- "$RM_BIN_LINK"
  fi

  if [[ -e $RM_MANAGER_CURRENT || -L $RM_MANAGER_CURRENT ]]; then
    [[ -L $RM_MANAGER_CURRENT &&
       $(readlink -f "$RM_MANAGER_CURRENT" 2>/dev/null || true) == "$REMOVE_CURRENT_MANAGER_PATH" ]] || {
      rm_error '管理器 current 链接在卸载过程中发生变化'
      return "$RM_RC_RECOVERY_INCOMPLETE"
    }
    rm -f -- "$RM_MANAGER_CURRENT"
  fi

  remove_manager_version_dir "$REMOVE_CURRENT_MANAGER_PATH" || return $?
  if [[ -n $REMOVE_PREVIOUS_MANAGER_PATH && $REMOVE_PREVIOUS_MANAGER_PATH != "$REMOVE_CURRENT_MANAGER_PATH" ]]; then
    remove_manager_version_dir "$REMOVE_PREVIOUS_MANAGER_PATH" || return $?
  fi

  if [[ -d $RM_VERSION_BASE && ! -L $RM_VERSION_BASE ]]; then
    for d in "$RM_VERSION_BASE"/*; do
      [[ -d $d && ! -L $d ]] || continue
      if [[ -f $RM_TRUSTED_RELEASE_KEY && ! -L $RM_TRUSTED_RELEASE_KEY ]] &&
         update_verify_release_dir "$d" "$RM_TRUSTED_RELEASE_KEY" >/dev/null 2>&1; then
        rm -rf -- "$d"
      else
        remove_record_preserved "$d" '额外管理器版本无法证明为受信发行内容'
      fi
    done
    rmdir "$RM_VERSION_BASE" 2>/dev/null || true
  fi
  rmdir "$RM_INSTALL_BASE" 2>/dev/null || true
}

remove_safe_owned_dir() {
  local path=$1
  [[ ! -e $path && ! -L $path ]] && return 0
  [[ -d $path && ! -L $path ]] || {
    remove_record_preserved "$path" '目录类型异常'
    return 0
  }
  rm_assert_no_symlink_components "$(dirname "$path")" || return $?
  rm -rf -- "$path"
}

remove_cleanup_runtime_state() {
  remove_safe_owned_dir "$RM_VAR_DIR/evidence" || return $?
  remove_safe_owned_dir "$RM_TX_DIR" || return $?
  remove_safe_owned_dir "$RM_TX_SNAPSHOT_DIR" || return $?
  remove_safe_owned_dir "$RM_RUN_DIR" || return $?

  if [[ -f $RM_STATE_FILE && ! -L $RM_STATE_FILE ]]; then
    rm -f -- "$RM_STATE_FILE"
  elif [[ -e $RM_STATE_FILE || -L $RM_STATE_FILE ]]; then
    remove_record_preserved "$RM_STATE_FILE" '状态路径类型异常'
  fi

  rmdir "$RM_XRAY_ETC_DIR" 2>/dev/null || true
  rmdir "$RM_VAR_DIR" 2>/dev/null || true
}

remove_all_nodes_and_manager() {
  local purge_backups=${1:-false} purge_exports=${2:-false}
  [[ $purge_backups == true || $purge_backups == false ]] || return "$RM_RC_PRECONDITION"
  [[ $purge_exports == true || $purge_exports == false ]] || return "$RM_RC_PRECONDITION"
  rm_require_root || return $?
  state_init >/dev/null || return $?

  REMOVE_PRESERVED_PATHS=()
  remove_preflight || return $?

  local recovery_backup='' nid preserved='[]' p rc=0
  if [[ $purge_backups == false ]]; then
    rm_capture_output recovery_backup backup_create config || {
      rc=$?
      rm_error '卸载前恢复点创建失败，拒绝继续卸载。'
      return "$rc"
    }
  fi

  while IFS= read -r nid; do
    [[ -n $nid ]] || continue
    fw_expire_temp "$nid" || return $?
    fw_remove_node_rules "$nid" || return $?
  done < <(jq -r '.nodes[].node_id' "$RM_STATE_FILE")

  remove_dynamic_temp_units || return $?
  remove_disable_runtime_units
  remove_delete_runtime_unit_files || return $?
  remove_owned_file_if_unchanged "$RM_XRAY_CONFIG"
  remove_managed_core_files || return $?
  remove_managed_manager_files || return $?

  [[ $purge_exports == true ]] && remove_exports_only
  [[ $purge_backups == true ]] && remove_backups_only
  remove_cleanup_runtime_state || return $?

  for p in "${REMOVE_PRESERVED_PATHS[@]}"; do
    preserved=$(jq -c --arg p "$p" '. + [$p] | unique' <<<"$preserved")
  done

  jq -n --arg backup "$recovery_backup" --argjson backups_removed "$purge_backups" \
    --argjson exports_removed "$purge_exports" --argjson preserved "$preserved" '{
      status:"manager_and_nodes_removed",
      security_preserved:[
        "SSH security policy and authorized keys",
        "UFW service/default policy and administrator rules",
        "Fail2ban installation/configuration",
        "trusted release key"
      ],
      managed_node_ufw_rules_removed:true,
      backups_removed:$backups_removed,
      exports_removed:$exports_removed,
      recovery_backup_id:(if $backup=="" then null else $backup end),
      preserved_paths:$preserved,
      note:"仅删除能够证明归 AsterNode 管理的运行时/版本/辅助单元；无法证明所有权或已漂移的额外版本会保留并报告。"
    }'
}

remove_backups_only() {
  [[ ! -e $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]] && return 0
  [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]] || return "$RM_RC_PRECONDITION"
  rm_assert_no_symlink_components "$(dirname "$RM_BACKUP_DIR")" || return $?
  rm -rf -- "$RM_BACKUP_DIR"
}

remove_exports_only() {
  [[ ! -e $RM_EXPORT_DIR && ! -L $RM_EXPORT_DIR ]] && return 0
  [[ -d $RM_EXPORT_DIR && ! -L $RM_EXPORT_DIR ]] || return "$RM_RC_PRECONDITION"
  rm_assert_no_symlink_components "$(dirname "$RM_EXPORT_DIR")" || return $?
  rm -rf -- "$RM_EXPORT_DIR"
}
