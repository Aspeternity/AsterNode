#!/usr/bin/env bash
# Managed node and upstream state orchestration.
# shellcheck source=lib/core-xray.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/core-xray.sh"

RM_PROTOCOL_VR="$RM_PROJECT_DIR/protocols/vless-reality.sh"

node_id_new() { printf 'node-%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }
upstream_id_new() { printf 'up-%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }

node_normalize_sources_in_file() {
  local f=$1 tmp count i j addr norm
  count=$(jq '.upstreams|length' "$f")
  tmp=$(mktemp "${f}.norm.XXXX") || return 1
  cp "$f" "$tmp"
  for ((i=0;i<count;i++)); do
    local sc; sc=$(jq ".upstreams[$i].source_addresses|length" "$tmp" 2>/dev/null || printf 0)
    for ((j=0;j<sc;j++)); do
      addr=$(jq -er ".upstreams[$i].source_addresses[$j]" "$tmp") || { rm -f "$tmp"; return "$RM_RC_PRECONDITION"; }
      norm=$(rm_normalize_ip_or_cidr "$addr") || { rm_error "无效线路机来源: $addr"; rm -f "$tmp"; return "$RM_RC_PRECONDITION"; }
      local t2; t2=$(mktemp "${f}.norm2.XXXX")
      jq --argjson i "$i" --argjson j "$j" --arg v "$norm" '.upstreams[$i].source_addresses[$j]=$v' "$tmp" >"$t2" && mv "$t2" "$tmp"
    done
  done
  mv "$tmp" "$f"
}

node_enrich_upsert_input() {
  local input=$1 output=$2
  state_init >/dev/null
  jq --slurpfile st "$RM_STATE_FILE" '
    ($st[0]) as $s |
    (.node.node_id // "") as $nid |
    if $nid == "" then .
    else
      ([ $s.nodes[] | select(.node_id==$nid) ] | first // {}) as $oldn |
      .node.reality = (($oldn.reality // {}) * (.node.reality // {})) |
      .node.created_at = (.node.created_at // $oldn.created_at // null) |
      .upstreams = [(.upstreams // [])[] as $u |
        ([ $s.upstreams[] | select(.upstream_id==($u.upstream_id // "")) ] | first // {}) as $oldu |
        $u
        | .uuid = (.uuid // $oldu.uuid // null)
        | .created_at = (.created_at // $oldu.created_at // null)
      ]
    end
  ' "$input" >"$output"
}

node_prepare_spec() {
  local input=$1 output=$2 xray=${3:-$(xray_current_binary)}
  rm_json_valid "$input" || { rm_error '节点输入 JSON 无效'; return "$RM_RC_PRECONDITION"; }
  jq '.' "$input" >"$output"
  node_normalize_sources_in_file "$output" || return $?
  local nid sid priv pass uid i count
  nid=$(jq -r '.node.node_id // empty' "$output"); [[ -n $nid ]] || nid=$(node_id_new)
  sid=$(jq -r '.node.reality.short_id // empty' "$output"); [[ -n $sid ]] || sid=$($RM_PROTOCOL_VR generate_short_id)
  priv=$(jq -r '.node.reality.private_key // empty' "$output"); pass=$(jq -r '.node.reality.password // empty' "$output")
  if [[ -z $priv || -z $pass ]]; then
    local kp; kp=$($RM_PROTOCOL_VR generate_keypair "$xray") || return $?
    priv=$(jq -r .private_key <<<"$kp"); pass=$(jq -r .password <<<"$kp")
  fi
  local tmp; tmp=$(mktemp "${output}.prep.XXXX")
  jq --arg nid "$nid" --arg sid "$sid" --arg priv "$priv" --arg pass "$pass" --arg flow xtls-rprx-vision \
    '.node.node_id=$nid | .node.protocol="vless-reality" | .node.flow=(.node.flow//$flow) |
     .node.access_mode=(.node.access_mode//"whitelist") | .node.enabled=(.node.enabled//true) | .node.autostart=(.node.autostart//true) |
     .node.reality=((.node.reality//{}) + {private_key:$priv,password:$pass,short_id:$sid}) |
     .upstreams=(.upstreams//[])' "$output" >"$tmp"
  mv "$tmp" "$output"
  count=$(jq '.upstreams|length' "$output")
  for ((i=0;i<count;i++)); do
    uid=$(jq -r ".upstreams[$i].uuid // empty" "$output"); [[ -n $uid ]] || uid=$($RM_PROTOCOL_VR generate_uuid "$xray")
    local upid; upid=$(jq -r ".upstreams[$i].upstream_id // empty" "$output"); [[ -n $upid ]] || upid=$(upstream_id_new)
    tmp=$(mktemp "${output}.prep.XXXX")
    jq --argjson i "$i" --arg uuid "$uid" --arg upid "$upid" --arg nid "$nid" \
      '.upstreams[$i].uuid=$uuid | .upstreams[$i].upstream_id=$upid | .upstreams[$i].node_id=$nid |
       .upstreams[$i].enabled=(.upstreams[$i].enabled//true) | .upstreams[$i].source_addresses=(.upstreams[$i].source_addresses//[])' "$output" >"$tmp"
    mv "$tmp" "$output"
  done
  "$RM_PROTOCOL_VR" validate "$output"
}

_node_sources_rebuild_filter='def srcs:
  [.upstreams[] as $u | ($u.source_addresses // [])[] as $a | {address:$a,note:("线路机来源: "+$u.name),upstream_id:$u.upstream_id}]
  | sort_by(.address) | group_by(.address)
  | map({address:.[0].address,note:.[0].note,upstream_ids:(map(.upstream_id)|unique)});
  .sources=srcs'

node_candidate_from_spec() {
  local spec=$1 candidate=$2 mode=${3:-upsert} nid now
  state_init >/dev/null
  nid=$(jq -er '.node.node_id' "$spec") || return "$RM_RC_PRECONDITION"
  now=$(rm_now)
  if [[ $mode == create ]] && jq -e --arg id "$nid" '.nodes[]|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then rm_error 'node_id 已存在'; return "$RM_RC_PRECONDITION"; fi
  jq --arg nid "$nid" --arg now "$now" --arg manager "$RM_MANAGER_VERSION" --arg core "$(xray_default_version)" --slurpfile spec "$spec" '
    . as $state | ($spec[0]) as $s |
    ([ $state.nodes[] | select(.node_id==$nid) ] | first // {}) as $oldn |
    .nodes = ([.nodes[] | select(.node_id != $nid)] + [($s.node + {created_at:($s.node.created_at // $oldn.created_at // $now),updated_at:$now})]) |
    .upstreams = ([.upstreams[] | select(.node_id != $nid)] + [
      $s.upstreams[] as $u |
      ([ $state.upstreams[] | select(.upstream_id==$u.upstream_id) ] | first // {}) as $oldu |
      ($u + {created_at:($u.created_at // $oldu.created_at // $now),updated_at:$now})
    ]) |
    .manager_version=$manager | .core_version=$core | .config_revision += 1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
}

xray_render_state_config() {
  local state_file=$1 out=$2 tmpdir cfg spec node_count i nid upcount enabled
  rm_json_valid "$state_file" || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir)
  printf '%s\n' '{"log":{"loglevel":"warning","access":"none"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}]}' >"$out"
  node_count=$(jq '.nodes|length' "$state_file")
  for ((i=0;i<node_count;i++)); do
    enabled=$(jq -r ".nodes[$i].enabled // true" "$state_file"); [[ $enabled == true ]] || continue
    nid=$(jq -r ".nodes[$i].node_id" "$state_file")
    spec="$tmpdir/spec-$i.json"; cfg="$tmpdir/cfg-$i.json"
    jq --arg nid "$nid" '
      (.nodes[]|select(.node_id==$nid)) as $n |
      {node:$n,upstreams:[.upstreams[]|select(.node_id==$nid and ((.enabled//true)==true))]}
      | .upstreams += [.upstreams[] | select(.pending_uuid? != null) | .uuid=.pending_uuid | .upstream_id=(.upstream_id+"-pending")]
    ' "$state_file" >"$spec"
    upcount=$(jq '.upstreams|length' "$spec")
    ((upcount>0)) || { rm_error "启用节点 $nid 没有启用的线路机凭据"; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    "$RM_PROTOCOL_VR" render_server "$spec" >"$cfg" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    local merge; merge=$(mktemp "$tmpdir/merge.XXXX")
    jq -s '.[0].inbounds += .[1].inbounds | .[0]' "$out" "$cfg" >"$merge" && mv "$merge" "$out"
  done
  rm -rf "$tmpdir"
}

node_candidate_validate_ids() {
  local f=$1
  jq -e '
    (([.nodes[].node_id]|length) == ([.nodes[].node_id]|unique|length)) and
    (([.upstreams[].upstream_id]|length) == ([.upstreams[].upstream_id]|unique|length)) and
    (([.upstreams[].uuid|ascii_downcase]|length) == ([.upstreams[].uuid|ascii_downcase]|unique|length))
  ' "$f" >/dev/null || {
    rm_error '节点 ID、线路机 ID 或 UUID 存在重复'; return "$RM_RC_PRECONDITION";
  }
}

node_candidate_validate_bindings() {
  local f=$1
  jq -e '
    ([.nodes[]|select((.enabled//true)==true)|.listen_port] as $p | ($p|length)==($p|unique|length)) and
    ([.nodes[]|select((.enabled//true)==true)|(.autostart//true)] | unique | length <= 1)
  ' "$f" >/dev/null || {
    rm_error '启用节点之间存在重复监听端口，或共享 Xray 进程存在互相冲突的 autostart 设置'
    return "$RM_RC_PRECONDITION"
  }
}

node_port_preflight_candidate() {
  local f=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  rm_have ss || { rm_error '缺少 ss，无法在应用前确认监听端口占用'; return "$RM_RC_PRECONDITION"; }
  local mainpid lines nid port
  mainpid=$(systemctl show -p MainPID --value "$RM_XRAY_SERVICE" 2>/dev/null || printf '0')
  [[ $mainpid =~ ^[0-9]+$ ]] || mainpid=0
  while IFS=
node_apply_candidate_state() {
  local candidate=$1 type=${2:-node-change} confirm=${3:-true} service_mode=${4:-normal}
  [[ $confirm == true || $confirm == false ]] || return "$RM_RC_PRECONDITION"
  [[ $service_mode == normal || $service_mode == preserve ]] || return "$RM_RC_PRECONDITION"
  node_candidate_validate_ids "$candidate" || return $?
  node_candidate_validate_bindings "$candidate" || return $?

  local tmpdir config core tx rc=0 enabled_count autostart was_active=false
  tmpdir=$(rm_safe_tmpdir); config="$tmpdir/config.json"
  xray_render_state_config "$candidate" "$config" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  enabled_count=$(jq '[.nodes[]|select((.enabled//true)==true)]|length' "$candidate")
  core=$(xray_current_binary)

  if ((enabled_count>0)); then
    xray_core_installed "$(xray_default_version)" || { rm_error '请先安装受管 Xray 核心'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    xray_test_config "$config" "$core" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    xray_ensure_user || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    node_port_preflight_candidate "$candidate" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  fi

  if [[ $confirm == true && ${RM_TEST_MODE} != 1 ]]; then
    node_print_change_summary "$candidate" "$type"
    rm_confirm '确认应用上述变更?' || { rm -rf "$tmpdir"; return "$RM_RC_CANCEL"; }
    ((enabled_count==0)) || node_port_preflight_candidate "$candidate" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  fi

  rm_service_is_active "$RM_XRAY_SERVICE" && was_active=true || true
  local cfgsha; cfgsha=$(rm_sha256_file "$config")
  local c2; c2=$(mktemp "$tmpdir/state.XXXX")
  jq --arg cfgsha "$cfgsha" '
    .owned_files = ([.owned_files[]|select(.path!="/etc/relay-manager-xray/config.json")] + [{path:"/etc/relay-manager-xray/config.json",sha256:$cfgsha}])
  ' "$candidate" >"$c2"; mv "$c2" "$candidate"

  tx=$(tx_begin "$type") || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  tx_record_service "$tx" "$RM_XRAY_SERVICE" || true
  tx_stage_file "$tx" "$candidate" "$RM_STATE_FILE" 0600 root:root || { tx_rollback "$tx" 'state stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$config" "$RM_XRAY_CONFIG" 0640 root:rm-xray || { tx_rollback "$tx" 'config stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }

  if ((enabled_count>0)); then
    if ! xray_test_config_as_service_user "$RM_XRAY_CONFIG" "$core"; then
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'rm-xray config validation failed' || rc=$?
      [[ $was_active == true ]] && rm_systemctl restart "$RM_XRAY_SERVICE" || true
      rm -rf "$tmpdir"; return "$rc"
    fi
    autostart=$(jq -r '[.nodes[]|select((.enabled//true)==true)] | if length==0 then true else .[0].autostart // true end' "$candidate")
    if [[ $service_mode == normal || $was_active == true ]]; then
      if ! xray_service_enable_start "$autostart"; then
        rc=$RM_RC_APPLY_ROLLED_BACK
        tx_rollback "$tx" 'Xray service start failed' || rc=$?
        [[ $was_active == true ]] && rm_systemctl restart "$RM_XRAY_SERVICE" || true
        rm -rf "$tmpdir"; return "$rc"
      fi
      tx_mark_service_changed "$tx" "$RM_XRAY_SERVICE" || true
    fi
  elif [[ $service_mode == normal || $was_active == true ]]; then
    rm_systemctl stop "$RM_XRAY_SERVICE" || true
    tx_mark_service_changed "$tx" "$RM_XRAY_SERVICE" || true
  fi

  tx_commit "$tx" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  rm -rf "$tmpdir"
}
node_create_or_replace_spec() {
  local input=$1 mode=${2:-create} tmpdir spec candidate
  rm_require_root || return $?
  xray_check_external_conflict || return $?
  state_init >/dev/null
  tmpdir=$(rm_safe_tmpdir); spec="$tmpdir/spec.json"; candidate="$tmpdir/state.json"
  if [[ $mode == upsert ]]; then
    node_enrich_upsert_input "$input" "$tmpdir/enriched.json" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    input="$tmpdir/enriched.json"
  fi
  node_prepare_spec "$input" "$spec" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_candidate_from_spec "$spec" "$candidate" "$mode" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_apply_candidate_state "$candidate" "node-$mode" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq '{node_id:.node.node_id,upstream_ids:[.upstreams[].upstream_id]}' "$spec"
  rm -rf "$tmpdir"
}

node_delete() {
  local nid=$1 candidate tmpdir
  rm_require_root || return $?
  state_init >/dev/null; state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg nid "$nid" '.nodes=[.nodes[]|select(.node_id!=$nid)] | .upstreams=[.upstreams[]|select(.node_id!=$nid)] | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" node-delete; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

node_set_enabled() {
  local nid=$1 val=$2 tmpdir candidate
  [[ $val == true || $val == false ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null; state_get_node "$nid" >/dev/null || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg nid "$nid" --argjson val "$val" '(.nodes[]|select(.node_id==$nid)).enabled=$val | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" node-enable; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

upstream_add_from_json() {
  local nid=$1 input=$2 tmpdir candidate obj upid uuid xray
  state_init >/dev/null; state_get_node "$nid" >/dev/null || return "$RM_RC_PRECONDITION"
  rm_json_valid "$input" || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"; obj="$tmpdir/up.json"; xray=$(xray_current_binary)
  upid=$(jq -r '.upstream_id//empty' "$input"); [[ -n $upid ]] || upid=$(upstream_id_new)
  uuid=$(jq -r '.uuid//empty' "$input"); [[ -n $uuid ]] || uuid=$($RM_PROTOCOL_VR generate_uuid "$xray")
  jq --arg id "$upid" --arg nid "$nid" --arg uuid "$uuid" --arg now "$(rm_now)" '. + {upstream_id:$id,node_id:$nid,uuid:$uuid,enabled:(.enabled//true),source_addresses:(.source_addresses//[]),created_at:(.created_at//$now),updated_at:$now}' "$input" >"$obj"
  local i count addr norm t2; count=$(jq '.source_addresses|length' "$obj")
  for ((i=0;i<count;i++)); do addr=$(jq -r ".source_addresses[$i]" "$obj"); norm=$(rm_normalize_ip_or_cidr "$addr") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }; t2=$(mktemp "$tmpdir/up.XXXX"); jq --argjson i "$i" --arg v "$norm" '.source_addresses[$i]=$v' "$obj">"$t2"; mv "$t2" "$obj"; done
  [[ $upid =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  "$RM_PROTOCOL_VR" generate_uuid >/dev/null 2>&1 || true
  if ! "$RM_PROTOCOL_VR" validate <(jq --arg nid "$nid" --slurpfile u "$obj" '(.nodes[]|select(.node_id==$nid)) as $n | {node:$n,upstreams:$u}' "$RM_STATE_FILE"); then rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  if jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)' "$RM_STATE_FILE" >/dev/null; then rm_error 'upstream_id 已存在'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  jq --slurpfile u "$obj" '.upstreams += $u | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-add || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  printf '%s\n' "$upid"; rm -rf "$tmpdir"
}

upstream_delete() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null; state_get_upstream "$upid" >/dev/null || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '.upstreams=[.upstreams[]|select(.upstream_id!=$id)] | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-delete || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream >/dev/null 2>&1 && export_invalidate_upstream "$upid" || true
  rm -rf "$tmpdir"
}

upstream_update_from_json() {
  local upid=$1 input=$2 tmpdir obj candidate count i addr norm t2 rc
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || { rm_error '线路机不存在'; return "$RM_RC_PRECONDITION"; }
  rm_json_valid "$input" || return "$RM_RC_PRECONDITION"
  jq -e 'type=="object" and ((keys - ["name","note","source_addresses","enabled"])|length==0)' "$input" >/dev/null || {
    rm_error '线路机更新只允许 name/note/source_addresses/enabled'; return "$RM_RC_PRECONDITION";
  }
  tmpdir=$(rm_safe_tmpdir); obj="$tmpdir/up.json"; candidate="$tmpdir/state.json"
  jq --arg id "$upid" --slurpfile patch "$input" '
    (.upstreams[]|select(.upstream_id==$id)) * $patch[0]
    | .upstream_id=$id
  ' "$RM_STATE_FILE" >"$obj"
  local name enabled
  name=$(jq -er '.name' "$obj") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  enabled=$(jq -r '.enabled // true' "$obj")
  rm_valid_name "$name" || { rm_error '线路机名称格式错误'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  [[ $enabled == true || $enabled == false ]] || { rm_error 'enabled 必须是布尔值'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  count=$(jq '.source_addresses|length' "$obj")
  for ((i=0;i<count;i++)); do
    addr=$(jq -er ".source_addresses[$i]" "$obj") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    norm=$(rm_normalize_ip_or_cidr "$addr") || { rm_error "无效线路机来源: $addr"; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    t2=$(mktemp "$tmpdir/up.XXXX"); jq --argjson i "$i" --arg v "$norm" '.source_addresses[$i]=$v' "$obj" >"$t2"; mv "$t2" "$obj"
  done
  jq --arg id "$upid" --slurpfile obj "$obj" '
    .upstreams=[.upstreams[]|if .upstream_id==$id then $obj[0] else . end] | .config_revision+=1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-update || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream >/dev/null 2>&1 && export_invalidate_upstream "$upid" || true
  rm -rf "$tmpdir"
}

upstream_set_enabled() {
  local upid=$1 val=$2 tmpdir patch rc
  [[ $val == true || $val == false ]] || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); patch="$tmpdir/patch.json"
  jq -n --argjson enabled "$val" '{enabled:$enabled}' >"$patch"
  upstream_update_from_json "$upid" "$patch"; rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

upstream_show() {
  local upid=$1
  state_init >/dev/null
  state_get_upstream "$upid"
}

upstream_rotation_prepare() {
  local upid=$1 ttl=${2:-86400} tmpdir candidate uuid now deadline
  state_init >/dev/null; state_get_upstream "$upid" >/dev/null || return "$RM_RC_PRECONDITION"
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and .pending_uuid!=null)' "$RM_STATE_FILE" >/dev/null && { rm_error '已有待完成 UUID 轮换'; return "$RM_RC_PRECONDITION"; }
  uuid=$($RM_PROTOCOL_VR generate_uuid "$(xray_current_binary)") || return $?
  now=$(rm_epoch); deadline=$((now+ttl)); tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" --arg uuid "$uuid" --argjson deadline "$deadline" --arg now "$(rm_now)" '(.upstreams[]|select(.upstream_id==$id)) |= (.pending_uuid=$uuid|.rotation={status:"parallel",deadline_epoch:$deadline,prepared_at:$now}) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-prepare || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq -n --arg up "$upid" --arg uuid "$uuid" --argjson deadline "$deadline" '{upstream_id:$up,pending_uuid:$uuid,deadline_epoch:$deadline,status:"parallel"}'
  rm -rf "$tmpdir"
}

upstream_rotation_commit() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null || { rm_error '没有待提交 UUID'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '(.upstreams[]|select(.upstream_id==$id)) |= (.uuid=.pending_uuid|del(.pending_uuid,.rotation)) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-commit || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream >/dev/null 2>&1 && export_invalidate_upstream "$upid" || true
  rm -rf "$tmpdir"
}

upstream_rotation_cancel() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null || { rm_error '没有待取消 UUID'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '(.upstreams[]|select(.upstream_id==$id)) |= del(.pending_uuid,.rotation) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-cancel || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream_mode >/dev/null 2>&1 && export_invalidate_upstream_mode "$upid" pending || true
  rm -rf "$tmpdir"
}

upstream_rotation_reconcile_expired() {
  state_init >/dev/null
  local now tmpdir candidate count ids rc=0
  now=$(rm_epoch)
  count=$(jq --argjson now "$now" '[.upstreams[]|select((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now)]|length' "$RM_STATE_FILE")
  ((count>0)) || { jq -n '{status:"normal",expired_rotations:0}'; return 0; }
  ids=$(jq -r --argjson now "$now" '.upstreams[]|select((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now)|.upstream_id' "$RM_STATE_FILE")
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --argjson now "$now" '
    .upstreams |= map(if ((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now) then del(.pending_uuid,.rotation) else . end)
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotation-expire false preserve || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  if declare -F export_invalidate_upstream_mode >/dev/null 2>&1; then
    while IFS= read -r id; do [[ -n $id ]] && export_invalidate_upstream_mode "$id" pending || true; done <<<"$ids"
  fi
  jq -n --argjson count "$count" --arg ids "$ids" '{status:"normal",expired_rotations:$count,upstream_ids:($ids|split("\n")|map(select(length>0)))}'
  rm -rf "$tmpdir"
}
\t' read -r nid port; do
    [[ -n $nid ]] || continue
    lines=$(ss -H -lntp "sport = :$port" 2>/dev/null || true)
    [[ -n $lines ]] || continue
    if ((mainpid>0)) && ! grep -Evq "pid=$mainpid([,)]|$)" <<<"$lines"; then
      continue
    fi
    if ((mainpid>0)) && grep -q "pid=$mainpid" <<<"$lines" && ! grep -Ev "pid=$mainpid([,)]|$)" <<<"$lines" | grep -q .; then
      continue
    fi
    rm_error "节点 $nid 端口 $port 已被非受管进程占用，拒绝覆盖。\n${lines:0:1000}"
    return "$RM_RC_PRECONDITION"
  done < <(jq -r '.nodes[]|select((.enabled//true)==true)|[.node_id,(.listen_port|tostring)]|@tsv' "$f")
}

node_print_change_summary() {
  local candidate=$1 type=$2
  printf '将执行 %s；共享 Xray 进程可能重启。受影响的启用节点：\n' "$type" >&2
  jq -r '[.nodes[]|select((.enabled//true)==true)|.node_id] | if length==0 then "  (无)" else .[] | "  - "+. end' "$candidate" >&2
  printf '候选状态（凭据已隐藏）：\n' >&2
  jq '{
    nodes:[.nodes[]|{node_id,name,protocol,listen_address,listen_port,public_host,public_port,target,sni,access_mode,enabled,autostart}],
    upstreams:[.upstreams[]|{upstream_id,name,node_id,enabled,source_addresses,has_pending_rotation:(.pending_uuid?!=null)}]
  }' "$candidate" >&2
}

node_apply_candidate_state() {
  local candidate=$1 type=${2:-node-change}
  node_candidate_validate_ids "$candidate" || return $?
  local tmpdir config core tx rc=0
  tmpdir=$(rm_safe_tmpdir); config="$tmpdir/config.json"
  xray_render_state_config "$candidate" "$config" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  core=$(xray_current_binary)
  if jq -e '[.nodes[]|select((.enabled//true)==true)]|length>0' "$candidate" >/dev/null; then
    xray_core_installed "$(xray_default_version)" || { rm_error '请先安装受管 Xray 核心'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    xray_test_config "$config" "$core" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  fi
  local cfgsha; cfgsha=$(rm_sha256_file "$config")
  local c2; c2=$(mktemp "$tmpdir/state.XXXX")
  jq --arg cfgsha "$cfgsha" '
    .owned_files = ([.owned_files[]|select(.path!="/etc/relay-manager-xray/config.json")] + [{path:"/etc/relay-manager-xray/config.json",sha256:$cfgsha}])
  ' "$candidate" >"$c2"; mv "$c2" "$candidate"
  tx=$(tx_begin "$type") || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  tx_record_service "$tx" "$RM_XRAY_SERVICE" || true
  tx_stage_file "$tx" "$candidate" "$RM_STATE_FILE" 0600 root:root || { tx_rollback "$tx" 'state stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$config" "$RM_XRAY_CONFIG" 0640 root:rm-xray || { tx_rollback "$tx" 'config stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { rc=$?; tx_rollback "$tx" 'apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  if jq -e '[.nodes[]|select((.enabled//true)==true)]|length>0' "$candidate" >/dev/null; then
    if ! xray_service_enable_start "$(jq -r 'all(.nodes[]; (.autostart//true)==true)' "$candidate")"; then
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'Xray service start failed' || rc=$?
      rm_systemctl restart "$RM_XRAY_SERVICE" || true
      rm -rf "$tmpdir"; return "$rc"
    fi
  else
    rm_systemctl stop "$RM_XRAY_SERVICE" || true
  fi
  tx_commit "$tx" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  rm -rf "$tmpdir"
}

node_create_or_replace_spec() {
  local input=$1 mode=${2:-create} tmpdir spec candidate
  rm_require_root || return $?
  xray_check_external_conflict || return $?
  state_init >/dev/null
  tmpdir=$(rm_safe_tmpdir); spec="$tmpdir/spec.json"; candidate="$tmpdir/state.json"
  if [[ $mode == upsert ]]; then
    node_enrich_upsert_input "$input" "$tmpdir/enriched.json" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    input="$tmpdir/enriched.json"
  fi
  node_prepare_spec "$input" "$spec" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_candidate_from_spec "$spec" "$candidate" "$mode" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_apply_candidate_state "$candidate" "node-$mode" || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq '{node_id:.node.node_id,upstream_ids:[.upstreams[].upstream_id]}' "$spec"
  rm -rf "$tmpdir"
}

node_delete() {
  local nid=$1 candidate tmpdir
  rm_require_root || return $?
  state_init >/dev/null; state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg nid "$nid" '.nodes=[.nodes[]|select(.node_id!=$nid)] | .upstreams=[.upstreams[]|select(.node_id!=$nid)] | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" node-delete; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

node_set_enabled() {
  local nid=$1 val=$2 tmpdir candidate
  [[ $val == true || $val == false ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null; state_get_node "$nid" >/dev/null || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg nid "$nid" --argjson val "$val" '(.nodes[]|select(.node_id==$nid)).enabled=$val | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" node-enable; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

upstream_add_from_json() {
  local nid=$1 input=$2 tmpdir candidate obj upid uuid xray
  state_init >/dev/null; state_get_node "$nid" >/dev/null || return "$RM_RC_PRECONDITION"
  rm_json_valid "$input" || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"; obj="$tmpdir/up.json"; xray=$(xray_current_binary)
  upid=$(jq -r '.upstream_id//empty' "$input"); [[ -n $upid ]] || upid=$(upstream_id_new)
  uuid=$(jq -r '.uuid//empty' "$input"); [[ -n $uuid ]] || uuid=$($RM_PROTOCOL_VR generate_uuid "$xray")
  jq --arg id "$upid" --arg nid "$nid" --arg uuid "$uuid" --arg now "$(rm_now)" '. + {upstream_id:$id,node_id:$nid,uuid:$uuid,enabled:(.enabled//true),source_addresses:(.source_addresses//[]),created_at:(.created_at//$now),updated_at:$now}' "$input" >"$obj"
  local i count addr norm t2; count=$(jq '.source_addresses|length' "$obj")
  for ((i=0;i<count;i++)); do addr=$(jq -r ".source_addresses[$i]" "$obj"); norm=$(rm_normalize_ip_or_cidr "$addr") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }; t2=$(mktemp "$tmpdir/up.XXXX"); jq --argjson i "$i" --arg v "$norm" '.source_addresses[$i]=$v' "$obj">"$t2"; mv "$t2" "$obj"; done
  [[ $upid =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  "$RM_PROTOCOL_VR" generate_uuid >/dev/null 2>&1 || true
  if ! "$RM_PROTOCOL_VR" validate <(jq --arg nid "$nid" --slurpfile u "$obj" '(.nodes[]|select(.node_id==$nid)) as $n | {node:$n,upstreams:$u}' "$RM_STATE_FILE"); then rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  if jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)' "$RM_STATE_FILE" >/dev/null; then rm_error 'upstream_id 已存在'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; fi
  jq --slurpfile u "$obj" '.upstreams += $u | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-add || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  printf '%s\n' "$upid"; rm -rf "$tmpdir"
}

upstream_delete() {
  local upid=$1 tmpdir candidate
  state_init >/dev/null; state_get_upstream "$upid" >/dev/null || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '.upstreams=[.upstreams[]|select(.upstream_id!=$id)] | .config_revision+=1' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-delete; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

upstream_rotation_prepare() {
  local upid=$1 ttl=${2:-86400} tmpdir candidate uuid now deadline
  state_init >/dev/null; state_get_upstream "$upid" >/dev/null || return "$RM_RC_PRECONDITION"
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and .pending_uuid!=null)' "$RM_STATE_FILE" >/dev/null && { rm_error '已有待完成 UUID 轮换'; return "$RM_RC_PRECONDITION"; }
  uuid=$($RM_PROTOCOL_VR generate_uuid "$(xray_current_binary)") || return $?
  now=$(rm_epoch); deadline=$((now+ttl)); tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" --arg uuid "$uuid" --argjson deadline "$deadline" --arg now "$(rm_now)" '(.upstreams[]|select(.upstream_id==$id)) |= (.pending_uuid=$uuid|.rotation={status:"parallel",deadline_epoch:$deadline,prepared_at:$now}) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-prepare || { local rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq -n --arg up "$upid" --arg uuid "$uuid" --argjson deadline "$deadline" '{upstream_id:$up,pending_uuid:$uuid,deadline_epoch:$deadline,status:"parallel"}'
  rm -rf "$tmpdir"
}

upstream_rotation_commit() {
  local upid=$1 tmpdir candidate
  state_init >/dev/null
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null || { rm_error '没有待提交 UUID'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '(.upstreams[]|select(.upstream_id==$id)) |= (.uuid=.pending_uuid|del(.pending_uuid,.rotation)) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-commit; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}

upstream_rotation_cancel() {
  local upid=$1 tmpdir candidate
  state_init >/dev/null
  tmpdir=$(rm_safe_tmpdir); candidate="$tmpdir/state.json"
  jq --arg id "$upid" '(.upstreams[]|select(.upstream_id==$id)) |= del(.pending_uuid,.rotation) | .config_revision+=1' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-cancel; local rc=$?; rm -rf "$tmpdir"; return "$rc"
}
