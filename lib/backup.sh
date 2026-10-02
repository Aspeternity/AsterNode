#!/usr/bin/env bash
# Controlled backups and restore points for managed state.
# shellcheck source=lib/node.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/node.sh"

RM_BACKUP_DIR="$RM_VAR_DIR/backups"
RM_BACKUP_LIMIT_BYTES=${RM_BACKUP_LIMIT_BYTES:-209715200}

backup_init() { rm_mkdir_secure 0700 "$RM_BACKUP_DIR"; }

backup_id_new() { printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; }

backup_copy_one() {
  local root=$1 logical=$2 src dst mode uid gid sha
  src=$(rm_path "$logical"); [[ -e $src ]] || return 0
  [[ -f $src && ! -L $src ]] || { rm_error "备份拒绝非常规文件: $logical"; return "$RM_RC_PRECONDITION"; }
  dst="$root/files$logical"; mkdir -p "$(dirname "$dst")"; cp -- "$src" "$dst"; chmod 0600 "$dst"
  mode=$(stat -c '%a' "$src"); uid=$(stat -c '%u' "$src"); gid=$(stat -c '%g' "$src"); sha=$(rm_sha256_file "$src")
  jq -n --arg path "$logical" --arg sha "$sha" --arg mode "$mode" --arg uid "$uid" --arg gid "$gid" '{path:$path,sha256:$sha,mode:$mode,uid:$uid,gid:$gid}' >>"$root/manifest.entries"
}

backup_create() {
  local kind=${1:-config}; [[ $kind == config || $kind == upgrade ]] || return "$RM_RC_PRECONDITION"
  rm_require_root || return $?; state_init >/dev/null; backup_init
  local id root corev
  id=$(backup_id_new); root="$RM_BACKUP_DIR/$id"; install -d -m 0700 "$root/files"
  : >"$root/manifest.entries"
  backup_copy_one "$root" /etc/relay-manager/state.json || { rm -rf "$root"; return $?; }
  backup_copy_one "$root" /etc/relay-manager-xray/config.json || { rm -rf "$root"; return $?; }
  backup_copy_one "$root" /etc/systemd/system/relay-manager-xray.service || { rm -rf "$root"; return $?; }
  if [[ $kind == upgrade ]]; then
    corev=$(jq -r '.core_version//empty' "$RM_STATE_FILE")
    [[ -n $corev ]] && backup_copy_one "$root" "/usr/local/lib/relay-manager/core/$corev/xray" || true
  else corev=$(jq -r '.core_version//empty' "$RM_STATE_FILE"); fi
  jq -s --arg id "$id" --arg kind "$kind" --arg created "$(rm_now)" --arg schema "$RM_SCHEMA_VERSION" --arg manager "$RM_MANAGER_VERSION" --arg core "$corev" \
    '{backup_id:$id,kind:$kind,created_at:$created,schema_version:($schema|tonumber),manager_version:$manager,core_version:(if $core=="" then null else $core end),files:.}' "$root/manifest.entries" >"$root/manifest.json"
  rm -f "$root/manifest.entries"; chmod 0600 "$root/manifest.json"
  backup_verify "$id" || { rm_error '刚创建的备份校验失败'; return "$RM_RC_INTERNAL"; }
  backup_prune
  printf '%s\n' "$id"
}

backup_verify() {
  local id=$1 root="$RM_BACKUP_DIR/$id" manifest="$RM_BACKUP_DIR/$id/manifest.json" count i p sha actual
  [[ -d $root && -f $manifest && ! -L $root && ! -L $manifest ]] || return "$RM_RC_PRECONDITION"
  jq -e --argjson schema "$RM_SCHEMA_VERSION" '.schema_version==$schema and (.files|type=="array")' "$manifest" >/dev/null || return "$RM_RC_PRECONDITION"
  count=$(jq '.files|length' "$manifest")
  for ((i=0;i<count;i++)); do
    p=$(jq -er ".files[$i].path" "$manifest") || return "$RM_RC_PRECONDITION"
    [[ $p == /* && $p != *'/../'* && $p != */.. ]] || return "$RM_RC_PRECONDITION"
    case "$p" in /etc/relay-manager/*|/etc/relay-manager-xray/*|/etc/systemd/system/relay-manager-xray.service|/usr/local/lib/relay-manager/core/*/xray) ;; *) return "$RM_RC_PRECONDITION";; esac
    [[ -f "$root/files$p" && ! -L "$root/files$p" ]] || return "$RM_RC_PRECONDITION"
    sha=$(jq -r ".files[$i].sha256" "$manifest"); actual=$(rm_sha256_file "$root/files$p"); [[ $sha == "$actual" ]] || return "$RM_RC_PRECONDITION"
  done
}

backup_restore_local() {
  local id=$1 root="$RM_BACKUP_DIR/$id" manifest="$RM_BACKUP_DIR/$id/manifest.json" tx count i p mode owner uid gid rc=0
  rm_require_root || return $?; backup_verify "$id" || { rm_error '备份校验失败'; return "$RM_RC_PRECONDITION"; }
  # Validate backed-up runtime config before touching the active one when possible.
  if [[ -f "$root/files/etc/relay-manager-xray/config.json" && -x $(xray_current_binary) ]]; then xray_test_config "$root/files/etc/relay-manager-xray/config.json" || return $?; fi
  tx=$(tx_begin backup-restore) || return $?
  count=$(jq '.files|length' "$manifest")
  for ((i=0;i<count;i++)); do
    p=$(jq -r ".files[$i].path" "$manifest")
    # Core binaries are restored by the update rollback path, not generic config restore.
    [[ $p == /usr/local/lib/relay-manager/core/*/xray ]] && continue
    mode=$(jq -r ".files[$i].mode" "$manifest"); uid=$(jq -r ".files[$i].uid" "$manifest"); gid=$(jq -r ".files[$i].gid" "$manifest"); owner="$uid:$gid"
    tx_stage_file "$tx" "$root/files$p" "$(rm_path "$p")" "$mode" "$owner" || { tx_rollback "$tx" 'restore staging failed' || true; return "$RM_RC_PRECONDITION"; }
  done
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'restore apply failed' || true; return "$rc"; }
  if [[ -f $RM_XRAY_CONFIG && -x $(xray_current_binary) ]]; then
    if ! xray_test_config "$RM_XRAY_CONFIG" || ! xray_service_enable_start true; then rc=$RM_RC_APPLY_ROLLED_BACK; tx_rollback "$tx" 'restored Xray failed validation' || rc=$?; return "$rc"; fi
  fi
  tx_commit "$tx"
}

backup_restore_nodes_only() {
  local id=$1 root="$RM_BACKUP_DIR/$id" oldstate current candidate tmpdir
  backup_verify "$id" || return "$RM_RC_PRECONDITION"
  oldstate="$root/files/etc/relay-manager/state.json"; [[ -f $oldstate ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null; current="$RM_STATE_FILE"; tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --slurpfile old "$oldstate" '($old[0]) as $o | .nodes=$o.nodes | .upstreams=$o.upstreams | .sources=$o.sources | .config_revision+=1' "$current" >"$candidate"
  rm_warn '跨机器节点恢复不会迁移 SSH/UFW/机器身份；请重新确认对外地址、端口与来源名单。'
  node_apply_candidate_state "$candidate" backup-nodes-only; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

backup_prune() {
  backup_init
  local ids id keep_config=0 keep_upgrade=0 kind size total=0
  mapfile -t ids < <(find "$RM_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  for id in "${ids[@]}"; do
    kind=$(jq -r '.kind//"config"' "$RM_BACKUP_DIR/$id/manifest.json" 2>/dev/null || printf config)
    if [[ $kind == upgrade ]]; then ((keep_upgrade+=1)); ((keep_upgrade<=1)) && continue; else ((keep_config+=1)); ((keep_config<=10)) && continue; fi
    rm -rf -- "$RM_BACKUP_DIR/$id"
  done
  size=$(du -sb "$RM_BACKUP_DIR" 2>/dev/null | awk '{print $1}'); total=${size:-0}
  if (( total > RM_BACKUP_LIMIT_BYTES )); then rm_warn "备份总量超过上限 ${RM_BACKUP_LIMIT_BYTES} 字节；为避免删除最近可用恢复点，未自动继续清理。"; fi
}

backup_list() {
  backup_init
  local m
  for m in "$RM_BACKUP_DIR"/*/manifest.json; do [[ -f $m ]] || continue; jq -c '{backup_id,kind,created_at,schema_version,manager_version,core_version}' "$m"; done | jq -s '.'
}
