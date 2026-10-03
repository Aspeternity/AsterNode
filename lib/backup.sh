#!/usr/bin/env bash
# Controlled backups and restore points for managed state.
# shellcheck source=lib/node.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/node.sh"

RM_BACKUP_DIR="$RM_VAR_DIR/backups"
RM_BACKUP_LIMIT_BYTES=${RM_BACKUP_LIMIT_BYTES:-209715200}
RM_BACKUP_KEEP_CONFIG=${RM_BACKUP_KEEP_CONFIG:-10}
RM_BACKUP_MIN_CONFIG=${RM_BACKUP_MIN_CONFIG:-2}
RM_BACKUP_KEEP_UPGRADE=${RM_BACKUP_KEEP_UPGRADE:-1}

RM_BACKUP_FORMAT=1

backup_init() { rm_mkdir_secure 0700 "$RM_BACKUP_DIR"; }

backup_id_valid() {
  [[ ${1:-} =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]
}

backup_id_new() { printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; }

backup_host_fingerprint() {
  local file value
  file=$(rm_path /etc/machine-id)
  [[ -f $file && ! -L $file ]] || return 1
  value=$(tr -d ' \t\r\n' <"$file")
  [[ $value =~ ^[0-9A-Fa-f]{32}$ ]] || return 1
  printf '%s' "${value,,}" | sha256sum | awk '{print $1}'
}

backup_xray_service_state_json() {
  local active=false enabled=false
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    [[ ${RM_BACKUP_TEST_XRAY_ACTIVE:-false} == true ]] && active=true
    [[ ${RM_BACKUP_TEST_XRAY_ENABLED:-false} == true ]] && enabled=true
  else
    rm_service_is_active "$RM_XRAY_SERVICE" && active=true || true
    rm_service_is_enabled "$RM_XRAY_SERVICE" && enabled=true || true
  fi
  jq -n --argjson active "$active" --argjson enabled "$enabled" '{active:$active,enabled:$enabled}'
}

backup_copy_one() {
  local root=$1 logical=$2 src dst mode uid gid sha
  src=$(rm_path "$logical"); [[ -e $src ]] || return 0
  [[ -f $src && ! -L $src ]] || { rm_error "备份拒绝非常规文件: $logical"; return "$RM_RC_PRECONDITION"; }
  dst="$root/files$logical"; mkdir -p "$(dirname "$dst")"; cp -- "$src" "$dst"; chmod 0600 "$dst"
  mode=$(stat -c '%a' "$src"); uid=$(stat -c '%u' "$src"); gid=$(stat -c '%g' "$src"); sha=$(rm_sha256_file "$src")
  jq -n --arg path "$logical" --arg sha "$sha" --arg mode "$mode" --arg uid "$uid" --arg gid "$gid" '{path:$path,sha256:$sha,mode:$mode,uid:$uid,gid:$gid}' >>"$root/manifest.entries"
}

backup_create() {
  local kind=${1:-config}
  [[ $kind == config || $kind == upgrade ]] || return "$RM_RC_PRECONDITION"
  rm_require_root || return $?
  state_init >/dev/null || return $?
  state_validate || return "$RM_RC_PRECONDITION"
  backup_init || return $?

  local id root corev host_fingerprint service_state copy_rc=0
  id=$(backup_id_new)
  backup_id_valid "$id" || return "$RM_RC_INTERNAL"
  root="$RM_BACKUP_DIR/$id"
  rm_mkdir_secure 0700 "$root" || return $?
  rm_mkdir_secure 0700 "$root/files" || { rm -rf -- "$root"; return "$RM_RC_INTERNAL"; }
  : >"$root/manifest.entries"
  chmod 0600 "$root/manifest.entries"

  backup_copy_one "$root" /etc/relay-manager/state.json || copy_rc=$?
  if ((copy_rc==0)); then backup_copy_one "$root" /etc/relay-manager-xray/config.json || copy_rc=$?; fi
  if ((copy_rc==0)); then backup_copy_one "$root" /etc/systemd/system/relay-manager-xray.service || copy_rc=$?; fi
  if ((copy_rc!=0)); then
    rm -rf -- "$root"
    return "$copy_rc"
  fi

  corev=$(jq -r '.core_version//empty' "$RM_STATE_FILE")
  if [[ $kind == upgrade && -n $corev ]]; then
    backup_copy_one "$root" "/usr/local/lib/relay-manager/core/$corev/xray" || copy_rc=$?
    if ((copy_rc!=0)); then rm -rf -- "$root"; return "$copy_rc"; fi
  fi

  host_fingerprint=$(backup_host_fingerprint 2>/dev/null || true)
  service_state=$(backup_xray_service_state_json)
  jq -s --argjson format "$RM_BACKUP_FORMAT" --arg id "$id" --arg kind "$kind" --arg created "$(rm_now)" \
    --arg schema "$RM_SCHEMA_VERSION" --arg manager "$RM_MANAGER_VERSION" --arg core "$corev" \
    --arg host "$host_fingerprint" --argjson service "$service_state" \
    '{backup_format:$format,backup_id:$id,kind:$kind,created_at:$created,
      schema_version:($schema|tonumber),manager_version:$manager,
      core_version:(if $core=="" then null else $core end),
      host_fingerprint:(if $host=="" then null else $host end),
      xray_service_state:$service,files:.}' \
    "$root/manifest.entries" >"$root/manifest.json"
  rm -f -- "$root/manifest.entries"
  chmod 0600 "$root/manifest.json"

  backup_verify "$id" || {
    rm_error '刚创建的备份校验失败'
    rm -rf -- "$root"
    return "$RM_RC_INTERNAL"
  }
  backup_prune
  printf '%s\n' "$id"
}
backup_verify() {
  local id root manifest count i p sha actual mode kind corev state_copy
  id=${1:-}
  backup_id_valid "$id" || return "$RM_RC_PRECONDITION"
  root="$RM_BACKUP_DIR/$id"
  manifest="$root/manifest.json"

  [[ -d $root && ! -L $root && -f $manifest && ! -L $manifest ]] || return "$RM_RC_PRECONDITION"
  [[ $(stat -c '%a' "$root") == 700 && $(stat -c '%a' "$manifest") == 600 ]] || return "$RM_RC_PRECONDITION"
  jq -e --arg id "$id" --argjson format "$RM_BACKUP_FORMAT" --argjson schema "$RM_SCHEMA_VERSION" '
    .backup_format==$format and
    .backup_id==$id and
    (.kind=="config" or .kind=="upgrade") and
    .schema_version==$schema and
    (.manager_version|type=="string" and length>0) and
    (.core_version==null or (.core_version|type=="string" and length>0)) and
    (.host_fingerprint==null or (.host_fingerprint|type=="string" and test("^[0-9a-f]{64}$"))) and
    (.xray_service_state|type=="object") and
    (.xray_service_state.active|type=="boolean") and
    (.xray_service_state.enabled|type=="boolean") and
    (.files|type=="array") and
    (([.files[].path]|length)==([.files[].path]|unique|length)) and
    ([.files[] |
      (.path|type=="string" and startswith("/")) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and
      (.mode|type=="string" and test("^[0-7]{3,4}$")) and
      (.uid|type=="string" and test("^[0-9]+$")) and
      (.gid|type=="string" and test("^[0-9]+$"))
    ] | all)
  ' "$manifest" >/dev/null || return "$RM_RC_PRECONDITION"

  count=$(jq '.files|length' "$manifest")
  for ((i=0;i<count;i++)); do
    p=$(jq -er ".files[$i].path" "$manifest") || return "$RM_RC_PRECONDITION"
    [[ $p == /* && $p != *'/../'* && $p != */.. ]] || return "$RM_RC_PRECONDITION"
    case "$p" in
      /etc/relay-manager/state.json|/etc/relay-manager-xray/config.json|/etc/systemd/system/relay-manager-xray.service|/usr/local/lib/relay-manager/core/*/xray) ;;
      *) return "$RM_RC_PRECONDITION" ;;
    esac
    [[ -f "$root/files$p" && ! -L "$root/files$p" ]] || return "$RM_RC_PRECONDITION"
    [[ $(stat -c '%a' "$root/files$p") == 600 ]] || return "$RM_RC_PRECONDITION"
    sha=$(jq -r ".files[$i].sha256" "$manifest")
    actual=$(rm_sha256_file "$root/files$p")
    [[ $sha == "$actual" ]] || return "$RM_RC_PRECONDITION"
    mode=$(jq -r ".files[$i].mode" "$manifest")
    [[ $mode =~ ^0?[0-7]{3}$ ]] || return "$RM_RC_PRECONDITION"
  done

  state_copy="$root/files/etc/relay-manager/state.json"
  [[ -f $state_copy ]] || return "$RM_RC_PRECONDITION"
  state_validate_file "$state_copy" || return "$RM_RC_PRECONDITION"

  kind=$(jq -r .kind "$manifest")
  corev=$(jq -r '.core_version//empty' "$manifest")
  if [[ $kind == upgrade && -n $corev ]]; then
    p="/usr/local/lib/relay-manager/core/$corev/xray"
    jq -e --arg p "$p" '.files[]|select(.path==$p)' "$manifest" >/dev/null || return "$RM_RC_PRECONDITION"
    [[ -f "$root/files$p" && ! -L "$root/files$p" ]] || return "$RM_RC_PRECONDITION"
  fi
}

backup_verify_json() {
  local id=${1:-}
  backup_verify "$id" || {
    rm_error "备份校验失败: $id"
    return "$RM_RC_PRECONDITION"
  }
  jq -n --arg id "$id" '{status:"verified",backup_id:$id}'
}
backup_candidate_from_state() {
  local oldstate=$1 current=$2 output=$3 portable=${4:-false}
  [[ $portable == true || $portable == false ]] || return "$RM_RC_PRECONDITION"
  jq --slurpfile old "$oldstate" --argjson portable "$portable" '
    ($old[0]) as $o |
    .nodes = ($o.nodes | map(
      if $portable then (.enabled=false | .autostart=false) else . end
    )) |
    .upstreams = ($o.upstreams | map(
      if $portable then (.enabled=false | del(.pending_uuid,.rotation)) else . end
    )) |
    .sources = (
      [.upstreams[] as $u | ($u.source_addresses // [])[] as $a |
        {address:$a,note:("线路机来源: "+($u.name // $u.upstream_id)),upstream_id:$u.upstream_id}]
      | sort_by(.address)
      | group_by(.address)
      | map({address:.[0].address,note:.[0].note,upstream_ids:(map(.upstream_id)|unique)})
    ) |
    .config_revision += 1
  ' "$current" >"$output"
  state_validate_file "$output"
}

backup_restore_local() {
  local id root manifest oldstate current_fp backup_fp tmpdir candidate rc=0
  id=${1:-}
  rm_require_root || return $?
  backup_verify "$id" || { rm_error '备份校验失败'; return "$RM_RC_PRECONDITION"; }
  root="$RM_BACKUP_DIR/$id"
  manifest="$root/manifest.json"
  oldstate="$root/files/etc/relay-manager/state.json"

  backup_fp=$(jq -r '.host_fingerprint//empty' "$manifest")
  current_fp=$(backup_host_fingerprint 2>/dev/null || true)
  [[ -n $backup_fp && -n $current_fp && $backup_fp == "$current_fp" ]] || {
    rm_error '无法证明该恢复点来自当前机器；完整恢复已拒绝。跨机器请使用 restore-nodes。'
    return "$RM_RC_PRECONDITION"
  }

  state_init >/dev/null || return $?
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  backup_candidate_from_state "$oldstate" "$RM_STATE_FILE" "$candidate" false || {
    rc=$?
    rm -rf -- "$tmpdir"
    return "$rc"
  }

  node_apply_candidate_state "$candidate" backup-restore true preserve || {
    rc=$?
    rm -rf -- "$tmpdir"
    return "$rc"
  }
  rm -rf -- "$tmpdir"
  jq -n --arg id "$id" '{
    status:"restored",backup_id:$id,scope:"same_host_nodes",
    runtime_service_state:"preserved",
    security_state:"preserved",
    note:"已按当前管理器/核心重新验证并生成 Xray 配置；SSH/UFW/Fail2ban 状态与当前机器安全所有权未被旧备份覆盖。"
  }'
}

backup_restore_nodes_only() {
  local id root oldstate tmpdir candidate rc=0 existing
  id=${1:-}
  rm_require_root || return $?
  backup_verify "$id" || { rm_error '备份校验失败'; return "$RM_RC_PRECONDITION"; }
  state_init >/dev/null || return $?

  existing=$(jq '(.nodes|length)+(.upstreams|length)' "$RM_STATE_FILE")
  ((existing==0)) || {
    rm_error '跨机器节点恢复只允许导入到当前无节点/线路机的状态，拒绝覆盖现有节点。'
    return "$RM_RC_PRECONDITION"
  }

  root="$RM_BACKUP_DIR/$id"
  oldstate="$root/files/etc/relay-manager/state.json"
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  backup_candidate_from_state "$oldstate" "$RM_STATE_FILE" "$candidate" true || {
    rc=$?
    rm -rf -- "$tmpdir"
    return "$rc"
  }

  rm_warn '跨机器恢复只导入节点/线路机数据，并强制保持禁用；不会迁移 SSH/UFW/Fail2ban、机器身份或已验证访问控制。'
  node_apply_candidate_state "$candidate" backup-nodes-only true preserve || {
    rc=$?
    rm -rf -- "$tmpdir"
    return "$rc"
  }
  rm -rf -- "$tmpdir"
  jq -n --arg id "$id" '{
    status:"restored_for_review",backup_id:$id,scope:"portable_nodes",
    nodes_enabled:false,upstreams_enabled:false,
    security_state:"not_migrated",
    requires_review:true,
    note:"请重新确认公网地址、监听端口、Target/SNI、来源地址与防火墙策略后，再逐项启用。"
  }'
}
backup_prune() {
  [[ ! -e $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]] && return 0
  [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]] || return "$RM_RC_PRECONDITION"
  [[ $RM_BACKUP_LIMIT_BYTES =~ ^[0-9]+$ && $RM_BACKUP_KEEP_CONFIG =~ ^[0-9]+$ &&
     $RM_BACKUP_MIN_CONFIG =~ ^[0-9]+$ && $RM_BACKUP_KEEP_UPGRADE =~ ^[0-9]+$ ]] ||
    return "$RM_RC_PRECONDITION"
  ((RM_BACKUP_KEEP_CONFIG>=RM_BACKUP_MIN_CONFIG && RM_BACKUP_MIN_CONFIG>=1 && RM_BACKUP_KEEP_UPGRADE>=1)) ||
    return "$RM_RC_PRECONDITION"

  local ids id keep_config=0 keep_upgrade=0 kind size total=0 config_count oldest
  mapfile -t ids < <(find "$RM_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  for id in "${ids[@]}"; do
    if ! backup_id_valid "$id" || ! backup_verify "$id"; then
      rm_warn "发现无效或非受管备份目录，保留不动: $id"
      continue
    fi
    kind=$(jq -r '.kind' "$RM_BACKUP_DIR/$id/manifest.json")
    if [[ $kind == upgrade ]]; then
      ((keep_upgrade+=1))
      ((keep_upgrade<=RM_BACKUP_KEEP_UPGRADE)) && continue
    else
      ((keep_config+=1))
      ((keep_config<=RM_BACKUP_KEEP_CONFIG)) && continue
    fi
    rm -rf -- "$RM_BACKUP_DIR/$id"
  done

  size=$(du -sb "$RM_BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  total=${size:-0}
  while ((total>RM_BACKUP_LIMIT_BYTES)); do
    config_count=$(backup_list | jq '[.[] | select(.valid==true and .kind=="config")] | length')
    ((config_count>RM_BACKUP_MIN_CONFIG)) || break
    oldest=$(backup_list | jq -r '[.[] | select(.valid==true and .kind=="config")] | reverse | .[0].backup_id // empty')
    [[ -n $oldest ]] || break
    rm -rf -- "$RM_BACKUP_DIR/$oldest"
    size=$(du -sb "$RM_BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    total=${size:-0}
  done

  if ((total>RM_BACKUP_LIMIT_BYTES)); then
    rm_warn "备份总量仍超过上限 ${RM_BACKUP_LIMIT_BYTES} 字节；最近 ${RM_BACKUP_MIN_CONFIG} 个配置恢复点和升级恢复点受保护，不继续自动删除。"
  fi
}
backup_list() {
  if [[ ! -e $RM_BACKUP_DIR ]]; then
    printf '[]\n'
    return 0
  fi
  [[ -d $RM_BACKUP_DIR && ! -L $RM_BACKUP_DIR ]] || return "$RM_RC_PRECONDITION"

  local m id item result='[]'
  for m in "$RM_BACKUP_DIR"/*/manifest.json; do
    [[ -f $m && ! -L $m ]] || continue
    id=${m%/manifest.json}
    id=${id##*/}
    backup_id_valid "$id" || continue
    if backup_verify "$id"; then
      item=$(jq -c '{
        backup_id,kind,created_at,schema_version,manager_version,core_version,
        host_fingerprint_present:(.host_fingerprint!=null),valid:true
      }' "$m")
    else
      item=$(jq -cn --arg id "$id" '{backup_id:$id,valid:false}')
    fi
    result=$(jq -c --argjson item "$item" '. + [$item]' <<<"$result")
  done
  jq 'sort_by(.created_at // "") | reverse' <<<"$result"
}
