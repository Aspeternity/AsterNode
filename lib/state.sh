#!/usr/bin/env bash
# Root-owned persistent state. This file is the source of truth for managed resources.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

RM_ETC_DIR="$(rm_path /etc/relay-manager)"
RM_VAR_DIR="$(rm_path /var/lib/relay-manager)"
RM_RUN_DIR="$(rm_path /run/relay-manager)"
RM_XRAY_ETC_DIR="$(rm_path /etc/relay-manager-xray)"
RM_STATE_FILE="$RM_ETC_DIR/state.json"
RM_LOCK_FILE="$RM_RUN_DIR/manager.lock"
RM_STATE_LOCK_FILE="$RM_RUN_DIR/state.lock"

state_init_dirs() {
  umask "$RM_UMASK"
  rm_mkdir_secure 0700 "$RM_ETC_DIR" || return $?
  rm_mkdir_secure 0700 "$RM_VAR_DIR" || return $?
  rm_mkdir_secure 0700 "$RM_RUN_DIR" || return $?
  if [[ -L $RM_XRAY_ETC_DIR || ( -e $RM_XRAY_ETC_DIR && ! -d $RM_XRAY_ETC_DIR ) ]]; then
    rm_error "Xray 配置目录路径异常: $RM_XRAY_ETC_DIR"
    return "$RM_RC_PRECONDITION"
  fi
  rm_assert_no_symlink_components "$(dirname -- "$RM_XRAY_ETC_DIR")" || return $?
  install -d -m 0750 -- "$RM_XRAY_ETC_DIR"
  chmod 0750 -- "$RM_XRAY_ETC_DIR"
  if [[ ${RM_TEST_MODE} != 1 && $(id -u) -eq 0 ]]; then
    if getent group rm-xray >/dev/null 2>&1; then
      chown root:rm-xray -- "$RM_XRAY_ETC_DIR"
    else
      chown root:root -- "$RM_XRAY_ETC_DIR"
    fi
  fi
}

state_lock_acquire() {
  state_init_dirs || return $?
  rm_require_cmds flock || return $?
  # shellcheck disable=SC3045
  exec {RM_STATE_LOCK_FD}>"$RM_STATE_LOCK_FILE" || return "$RM_RC_INTERNAL"
  flock -x "$RM_STATE_LOCK_FD" || return "$RM_RC_INTERNAL"
}

state_lock_release() {
  if [[ -n ${RM_STATE_LOCK_FD:-} ]]; then
    flock -u "$RM_STATE_LOCK_FD" 2>/dev/null || true
    # shellcheck disable=SC3045
    exec {RM_STATE_LOCK_FD}>&- || true
    unset RM_STATE_LOCK_FD
  fi
}

state_default_json() {
  jq -n \
    --argjson schema "$RM_SCHEMA_VERSION" \
    --arg manager "$RM_MANAGER_VERSION" \
    --arg now "$(rm_now)" \
    '{schema_version:$schema, manager_version:$manager, core_version:null, config_revision:0,
      created_at:$now, updated_at:$now,
      owned_files:[], owned_services:[], owned_firewall_rules:[],
      nodes:[], upstreams:[], sources:[], temporary_opens:[], external_drift:[],
      ssh_verifications:{}}'
}

state_validate_file() {
  local file=${1:-$RM_STATE_FILE}
  [[ -f $file && ! -L $file ]] || return 1
  jq -e --argjson schema "$RM_SCHEMA_VERSION" '
    (type=="object") and
    (.schema_version == $schema) and
    (.manager_version|type=="string") and
    (.config_revision|type=="number" and .>=0 and .==floor) and
    (.nodes|type=="array") and (.upstreams|type=="array") and (.sources|type=="array") and
    (.owned_files|type=="array") and (.owned_services|type=="array") and
    (.owned_firewall_rules|type=="array") and (.temporary_opens|type=="array") and
    ([.nodes[]? |
      (.node_id|type=="string" and length>0) and
      ((has("enabled")|not) or (.enabled|type=="boolean")) and
      ((has("autostart")|not) or (.autostart|type=="boolean"))
    ] | all) and
    ([.upstreams[]? |
      (.upstream_id|type=="string" and length>0) and
      (.node_id|type=="string" and length>0) and
      ((has("enabled")|not) or (.enabled|type=="boolean"))
    ] | all) and
    ([.sources[]? | (.address|type=="string" and length>0) and (.upstream_ids|type=="array")] | all) and
    (([.nodes[]?.node_id] | length) == ([.nodes[]?.node_id] | unique | length)) and
    (([.upstreams[]?.upstream_id] | length) == ([.upstreams[]?.upstream_id] | unique | length))
  ' "$file" >/dev/null
}

state_init() {
  state_init_dirs || return $?
  state_lock_acquire || return $?
  local rc=0
  if [[ ! -e $RM_STATE_FILE ]]; then
    local tmp
    tmp=$(mktemp "$RM_ETC_DIR/.state.XXXXXX") || { state_lock_release; return "$RM_RC_INTERNAL"; }
    state_default_json >"$tmp"
    rm_atomic_write "$tmp" "$RM_STATE_FILE" 0600 root:root || rc=$?
    rm -f -- "$tmp"
  elif [[ -L $RM_STATE_FILE || ! -f $RM_STATE_FILE ]]; then
    rm_error "状态路径不是普通文件: $RM_STATE_FILE"
    rc=$RM_RC_PRECONDITION
  fi
  if ((rc==0)) && ! state_validate_file "$RM_STATE_FILE"; then
    rm_error '状态文件 schema 或结构无效，拒绝自动覆盖。'
    rc=$RM_RC_PRECONDITION
  fi
  state_lock_release
  return "$rc"
}

state_validate() { state_validate_file "$RM_STATE_FILE"; }

state_read() {
  state_init >/dev/null || return $?
  cat -- "$RM_STATE_FILE"
}

state_update_filter() {
  local filter=$1; shift
  state_init >/dev/null || return $?
  state_lock_acquire || return $?
  local tmp rc=0
  tmp=$(mktemp "$RM_ETC_DIR/.state.XXXXXX") || { state_lock_release; return "$RM_RC_INTERNAL"; }
  if ! jq "$@" --arg now "$(rm_now)" "($filter) | .updated_at=\$now" "$RM_STATE_FILE" >"$tmp"; then
    rm -f -- "$tmp"; state_lock_release; return "$RM_RC_PRECONDITION"
  fi
  if ! state_validate_file "$tmp"; then
    rm_error '状态更新结果未通过 schema/唯一性检查。'
    rm -f -- "$tmp"; state_lock_release; return "$RM_RC_PRECONDITION"
  fi
  rm_atomic_write "$tmp" "$RM_STATE_FILE" 0600 root:root || rc=$?
  rm -f -- "$tmp"
  state_lock_release
  return "$rc"
}

state_bump_revision() { state_update_filter '.config_revision += 1'; }

state_add_owned_file() {
  local path=$1 sha=${2:-}
  [[ $path == /* ]] || return "$RM_RC_PRECONDITION"
  state_update_filter '.owned_files = ((.owned_files + [{path:$path,sha256:$sha}]) | unique_by(.path))' --arg path "$path" --arg sha "$sha"
}

state_add_owned_service() {
  local name=${1:?service name required}
  [[ $name =~ ^[A-Za-z0-9_.@:-]+$ ]] || return "$RM_RC_PRECONDITION"
  state_update_filter '.owned_services = ((.owned_services + [$name]) | unique)' --arg name "$name"
}

state_get_node() { jq -e --arg id "$1" '.nodes[] | select(.node_id==$id)' "$RM_STATE_FILE"; }
state_get_upstream() { jq -e --arg id "$1" '.upstreams[] | select(.upstream_id==$id)' "$RM_STATE_FILE"; }

state_put_node_file() {
  local f=$1 id
  [[ -f $f ]] || return "$RM_RC_PRECONDITION"
  id=$(jq -er '.node_id' "$f") || return "$RM_RC_PRECONDITION"
  state_update_filter '(.nodes = ([.nodes[] | select(.node_id != $id)] + [$obj]))' --arg id "$id" --argjson obj "$(cat "$f")"
}

state_put_upstream_file() {
  local f=$1 id
  [[ -f $f ]] || return "$RM_RC_PRECONDITION"
  id=$(jq -er '.upstream_id' "$f") || return "$RM_RC_PRECONDITION"
  state_update_filter '(.upstreams = ([.upstreams[] | select(.upstream_id != $id)] + [$obj]))' --arg id "$id" --argjson obj "$(cat "$f")"
}

state_remove_node() { local id=$1; state_update_filter '.nodes = [.nodes[] | select(.node_id != $id)]' --arg id "$id"; }
state_remove_upstream() { local id=$1; state_update_filter '.upstreams = [.upstreams[] | select(.upstream_id != $id)]' --arg id "$id"; }

state_record_source() {
  local addr=$1 note=${2:-} upstream_id=${3:-} norm
  norm=$(rm_normalize_ip_or_cidr "$addr") || { rm_error "无效 IP/CIDR: $addr"; return "$RM_RC_PRECONDITION"; }
  [[ -n $upstream_id ]] || return "$RM_RC_PRECONDITION"
  state_update_filter '
    ([.sources[] | select(.address==$addr)] | first // {address:$addr,note:$note,upstream_ids:[]}) as $old |
    .sources = ([.sources[] | select(.address != $addr)] + [($old | .note=$note | .upstream_ids=((.upstream_ids + [$up])|unique))])
  ' --arg addr "$norm" --arg note "$note" --arg up "$upstream_id"
}

state_unlink_source_upstream() {
  local addr=$1 up=$2 norm
  norm=$(rm_normalize_ip_or_cidr "$addr") || return "$RM_RC_PRECONDITION"
  state_update_filter '
    .sources = [.sources[] | if .address==$addr then .upstream_ids=[.upstream_ids[]|select(.!=$up)] else . end]
    | .sources = [.sources[] | select((.upstream_ids|length)>0)]
  ' --arg addr "$norm" --arg up "$up"
}
