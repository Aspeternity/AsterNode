#!/usr/bin/env bash
# Managed node and upstream state orchestration.
# shellcheck source=lib/core-xray.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/core-xray.sh"

RM_PROTOCOL_VR="$RM_PROJECT_DIR/protocols/vless-reality.sh"

node_id_new() { printf 'node-%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }
upstream_id_new() { printf 'up-%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }

node_normalize_sources_in_file() {
  local f=$1 tmp count i j addr norm t2
  count=$(jq '.upstreams|length' "$f")
  tmp=$(mktemp "${f}.norm.XXXX") || return "$RM_RC_INTERNAL"
  cp "$f" "$tmp"
  for ((i=0;i<count;i++)); do
    local sc
    sc=$(jq ".upstreams[$i].source_addresses|length" "$tmp" 2>/dev/null || printf 0)
    for ((j=0;j<sc;j++)); do
      addr=$(jq -er ".upstreams[$i].source_addresses[$j]" "$tmp") || { rm -f "$tmp"; return "$RM_RC_PRECONDITION"; }
      norm=$(rm_normalize_ip_or_cidr "$addr") || {
        rm_error "无效线路机来源: $addr"
        rm -f "$tmp"
        return "$RM_RC_PRECONDITION"
      }
      t2=$(mktemp "${f}.norm2.XXXX") || { rm -f "$tmp"; return "$RM_RC_INTERNAL"; }
      jq --argjson i "$i" --argjson j "$j" --arg v "$norm" '.upstreams[$i].source_addresses[$j]=$v' "$tmp" >"$t2" &&
        mv "$t2" "$tmp"
    done
  done
  mv "$tmp" "$f"
}

node_assert_no_direct_credential_change() {
  local input=$1 nid
  state_init >/dev/null
  nid=$(jq -r '.node.node_id // empty' "$input")
  [[ -n $nid ]] || return 0
  jq -e --arg id "$nid" '.nodes[]|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null || return 0

  if ! jq -e --arg nid "$nid" --slurpfile st "$RM_STATE_FILE" '
    ($st[0].nodes[]|select(.node_id==$nid)) as $old |
    ((.node.reality.private_key? // $old.reality.private_key) == $old.reality.private_key) and
    ((.node.reality.password? // $old.reality.password) == $old.reality.password) and
    ((.node.reality.short_id? // $old.reality.short_id) == $old.reality.short_id)
  ' "$input" >/dev/null; then
    rm_error '普通节点修改禁止直接替换 REALITY 密钥或 Short ID；请使用专用轮换操作。'
    return "$RM_RC_PRECONDITION"
  fi

  if ! jq -e --slurpfile st "$RM_STATE_FILE" '
    [
      (.upstreams // [])[] |
      . as $u |
      ([ $st[0].upstreams[] | select(.upstream_id==($u.upstream_id // "")) ] | first // null) as $old |
      ($old == null or (($u.uuid? // $old.uuid) == $old.uuid))
    ] | all
  ' "$input" >/dev/null; then
    rm_error '普通节点修改禁止直接替换已有线路机 UUID；请使用 UUID 轮换操作。'
    return "$RM_RC_PRECONDITION"
  fi
}

node_enrich_upsert_input() {
  local input=$1 output=$2
  state_init >/dev/null
  node_assert_no_direct_credential_change "$input" || return $?
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

  local nid sid priv pass fallback_limits uid i count tmp upid
  nid=$(jq -r '.node.node_id // empty' "$output")
  [[ -n $nid ]] || nid=$(node_id_new)
  sid=$(jq -r '.node.reality.short_id // empty' "$output")
  [[ -n $sid ]] || sid=$("$RM_PROTOCOL_VR" generate_short_id)
  priv=$(jq -r '.node.reality.private_key // empty' "$output")
  pass=$(jq -r '.node.reality.password // empty' "$output")
  if [[ -z $priv || -z $pass ]]; then
    local kp
    kp=$("$RM_PROTOCOL_VR" generate_keypair "$xray") || return $?
    priv=$(jq -r .private_key <<<"$kp")
    pass=$(jq -r .password <<<"$kp")
  fi
  fallback_limits=$(jq -c '.node.reality.fallback_limits // empty' "$output")
  [[ -n $fallback_limits ]] || fallback_limits=$("$RM_PROTOCOL_VR" generate_fallback_limits) || return $?

  tmp=$(mktemp "${output}.prep.XXXX") || return "$RM_RC_INTERNAL"
  jq --arg nid "$nid" --arg sid "$sid" --arg priv "$priv" --arg pass "$pass" --argjson fallback_limits "$fallback_limits" --arg flow xtls-rprx-vision '
    .node.node_id=$nid
    | .node.protocol="vless-reality"
    | .node.flow=(.node.flow//$flow)
    | .node.access_mode=(.node.access_mode//"whitelist")
    | .node.enabled=(if .node.enabled==null then true else .node.enabled end)
    | .node.autostart=(if .node.autostart==null then true else .node.autostart end)
    | .node.reality=((.node.reality//{}) + {private_key:$priv,password:$pass,short_id:$sid,fallback_limits:$fallback_limits})
    | .upstreams=(.upstreams//[])
  ' "$output" >"$tmp"
  mv "$tmp" "$output"

  count=$(jq '.upstreams|length' "$output")
  for ((i=0;i<count;i++)); do
    uid=$(jq -r ".upstreams[$i].uuid // empty" "$output")
    [[ -n $uid ]] || uid=$("$RM_PROTOCOL_VR" generate_uuid "$xray")
    upid=$(jq -r ".upstreams[$i].upstream_id // empty" "$output")
    [[ -n $upid ]] || upid=$(upstream_id_new)
    tmp=$(mktemp "${output}.prep.XXXX") || return "$RM_RC_INTERNAL"
    jq --argjson i "$i" --arg uuid "$uid" --arg upid "$upid" --arg nid "$nid" '
      .upstreams[$i].uuid=$uuid
      | .upstreams[$i].upstream_id=$upid
      | .upstreams[$i].node_id=$nid
      | .upstreams[$i].enabled=(if .upstreams[$i].enabled==null then true else .upstreams[$i].enabled end)
      | .upstreams[$i].source_addresses=(.upstreams[$i].source_addresses//[])
    ' "$output" >"$tmp"
    mv "$tmp" "$output"
  done

  "$RM_PROTOCOL_VR" validate "$output"
}

_node_sources_rebuild_filter='def srcs:
  [.upstreams[] as $u | ($u.source_addresses // [])[] as $a |
    {address:$a,note:("线路机来源: "+$u.name),upstream_id:$u.upstream_id}]
  | sort_by(.address)
  | group_by(.address)
  | map({address:.[0].address,note:.[0].note,upstream_ids:(map(.upstream_id)|unique)});
  .sources=srcs'

node_candidate_from_spec() {
  local spec=$1 candidate=$2 mode=${3:-upsert} nid now
  state_init >/dev/null
  nid=$(jq -er '.node.node_id' "$spec") || return "$RM_RC_PRECONDITION"
  now=$(rm_now)
  if [[ $mode == create ]] && jq -e --arg id "$nid" '.nodes[]|select(.node_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error 'node_id 已存在'
    return "$RM_RC_PRECONDITION"
  fi
  jq --arg nid "$nid" --arg now "$now" --arg manager "$RM_MANAGER_VERSION" --arg core "$(xray_default_version)" --slurpfile spec "$spec" '
    . as $state | ($spec[0]) as $s |
    ([ $state.nodes[] | select(.node_id==$nid) ] | first // {}) as $oldn |
    .nodes = ([.nodes[] | select(.node_id != $nid)] +
      [($s.node + {created_at:($s.node.created_at // $oldn.created_at // $now),updated_at:$now})]) |
    .upstreams = ([.upstreams[] | select(.node_id != $nid)] + [
      $s.upstreams[] as $u |
      ([ $state.upstreams[] | select(.upstream_id==$u.upstream_id) ] | first // {}) as $oldu |
      ($u + {created_at:($u.created_at // $oldu.created_at // $now),updated_at:$now})
    ]) |
    .manager_version=$manager | .core_version=$core | .config_revision += 1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
}

xray_render_state_config() {
  local state_file=$1 out=$2 tmpdir cfg spec node_count i nid upcount enabled merge
  rm_json_valid "$state_file" || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir) || return $?
  printf '%s\n' '{"log":{"loglevel":"warning","access":"none"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}]}' >"$out"
  node_count=$(jq '.nodes|length' "$state_file")
  for ((i=0;i<node_count;i++)); do
    enabled=$(jq -r "if .nodes[$i]|has(\"enabled\") then .nodes[$i].enabled else true end" "$state_file")
    [[ $enabled == true ]] || continue
    nid=$(jq -r ".nodes[$i].node_id" "$state_file")
    spec="$tmpdir/spec-$i.json"
    cfg="$tmpdir/cfg-$i.json"
    jq --arg nid "$nid" '
      (.nodes[]|select(.node_id==$nid)) as $n |
      {node:$n,upstreams:[.upstreams[]|select(.node_id==$nid and ((if has("enabled") then .enabled else true end)==true))]}
      | .upstreams += [.upstreams[] | select((.pending_uuid? // "") != "") |
        .uuid=.pending_uuid | .upstream_id=(.upstream_id+"-pending")]
    ' "$state_file" >"$spec"
    upcount=$(jq '.upstreams|length' "$spec")
    ((upcount>0)) || {
      rm_error "启用节点 $nid 没有启用的线路机凭据"
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    }
    "$RM_PROTOCOL_VR" render_server "$spec" >"$cfg" || {
      local rc=$?
      rm -rf "$tmpdir"
      return "$rc"
    }
    merge=$(mktemp "$tmpdir/merge.XXXX") || { rm -rf "$tmpdir"; return "$RM_RC_INTERNAL"; }
    jq -s '.[0].inbounds += .[1].inbounds | .[0]' "$out" "$cfg" >"$merge" && mv "$merge" "$out"
  done
  rm -rf "$tmpdir"
}

node_candidate_validate_ids() {
  local f=$1
  jq -e '
    (([.nodes[].node_id]|length) == ([.nodes[].node_id]|unique|length)) and
    (([.upstreams[].upstream_id]|length) == ([.upstreams[].upstream_id]|unique|length)) and
    (
      ([.upstreams[] | [.uuid, (.pending_uuid // empty)][] | select(length>0) | ascii_downcase] | length)
      ==
      ([.upstreams[] | [.uuid, (.pending_uuid // empty)][] | select(length>0) | ascii_downcase] | unique | length)
    )
  ' "$f" >/dev/null || {
    rm_error '节点 ID、线路机 ID 或 UUID 存在重复'
    return "$RM_RC_PRECONDITION"
  }
}

node_candidate_validate_bindings() {
  local f=$1
  jq -e '
    ([.nodes[]|select((if has("enabled") then .enabled else true end)==true)|.listen_port] as $p | ($p|length)==($p|unique|length)) and
    ([.nodes[]|select((if has("enabled") then .enabled else true end)==true)|(if has("autostart") then .autostart else true end)] | unique | length <= 1)
  ' "$f" >/dev/null || {
    rm_error '启用节点之间存在重复监听端口，或共享 Xray 进程存在互相冲突的 autostart 设置'
    return "$RM_RC_PRECONDITION"
  }
}

node_address_family_preflight_candidate() {
  local f=$1
  [[ ${RM_TEST_MODE} == 1 ]] && return 0

  if jq -e '[.nodes[]|select((if has("enabled") then .enabled else true end)==true and
      (.listen_address=="::" or .listen_address=="::1"))]|length>0' "$f" >/dev/null; then
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] &&
       [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 ]]; then
      rm_error '候选配置需要 IPv6 监听，但内核当前禁用了 IPv6。'
      return "$RM_RC_PRECONDITION"
    fi
    if rm_have ip && ! ip -6 addr show 2>/dev/null | grep -q 'inet6 '; then
      rm_error '候选配置需要 IPv6 监听，但系统未发现可用 IPv6 地址族。'
      return "$RM_RC_PRECONDITION"
    fi
  fi
}

node_port_preflight_candidate() {
  local f=$1 mainpid lines nid port foreign
  [[ ${RM_TEST_MODE} == 1 ]] && return 0
  rm_have ss || { rm_error '缺少 ss，无法在应用前确认监听端口占用'; return "$RM_RC_PRECONDITION"; }
  mainpid=$(systemctl show -p MainPID --value "$RM_XRAY_SERVICE" 2>/dev/null || printf '0')
  [[ $mainpid =~ ^[0-9]+$ ]] || mainpid=0
  while IFS=$'\t' read -r nid port; do
    [[ -n $nid ]] || continue
    lines=$(ss -H -lntp "sport = :$port" 2>/dev/null || true)
    [[ -n $lines ]] || continue
    if ((mainpid>0)); then
      foreign=$(grep -v "pid=$mainpid," <<<"$lines" || true)
      [[ -z $foreign ]] && continue
    fi
    rm_error "节点 $nid 端口 $port 已被非受管进程占用，拒绝覆盖。\n${lines:0:1000}"
    return "$RM_RC_PRECONDITION"
  done < <(jq -r '.nodes[]|select((if has("enabled") then .enabled else true end)==true)|[.node_id,(.listen_port|tostring)]|@tsv' "$f")
}

node_print_change_summary() {
  local candidate=$1 type=$2
  printf '将执行 %s；共享 Xray 进程可能重启。受影响的启用节点：\n' "$type" >&2
  jq -r '[.nodes[]|select((if has("enabled") then .enabled else true end)==true)|.node_id] |
    if length==0 then "  (无)" else .[] | "  - "+. end' "$candidate" >&2
  printf '候选状态（凭据已隐藏）：\n' >&2
  jq '{
    nodes:[.nodes[]|{node_id,name,protocol,listen_address,listen_port,public_host,public_port,target,sni,access_mode,enabled,autostart}],
    upstreams:[.upstreams[]|{upstream_id,name,node_id,enabled,source_addresses,has_pending_rotation:((.pending_uuid? // "")!="")}]
  }' "$candidate" >&2
}

node_assert_managed_config_not_drifted() {
  state_init >/dev/null || return $?
  local expected actual
  expected=$(jq -r --arg path '/etc/relay-manager-xray/config.json' '
    [.owned_files[]? | select(.path==$path) | .sha256][0] // empty
  ' "$RM_STATE_FILE")
  [[ -n $expected ]] || return 0
  if [[ ! -f $RM_XRAY_CONFIG || -L $RM_XRAY_CONFIG ]]; then
    rm_error '检测到受管 Xray 配置漂移：运行配置缺失或文件类型异常。请先对账，拒绝静默覆盖。'
    return "$RM_RC_PRECONDITION"
  fi
  actual=$(rm_sha256_file "$RM_XRAY_CONFIG")
  if [[ $actual != "$expected" ]]; then
    rm_error "检测到受管 Xray 配置被外部修改。expected=$expected actual=$actual；请先对账，拒绝静默覆盖。"
    return "$RM_RC_PRECONDITION"
  fi
}

node_apply_state_only_candidate() {
  local candidate=$1 type=${2:-state-only} confirm=${3:-true}
  node_candidate_validate_ids "$candidate" || return $?
  node_candidate_validate_bindings "$candidate" || return $?
  node_assert_managed_config_not_drifted || return $?

  if [[ $confirm == true && ${RM_TEST_MODE} != 1 ]]; then
    printf '将执行 %s；仅更新受管状态，不改写 Xray 运行配置，也不会主动重启 Xray。\n' "$type" >&2
    jq '{
      nodes:[.nodes[]|{node_id,name,enabled,autostart}],
      upstreams:[.upstreams[]|{upstream_id,name,node_id,enabled,source_addresses}]
    }' "$candidate" >&2
    rm_confirm '确认应用上述状态变更?' || return "$RM_RC_CANCEL"
  fi

  local expected_config_sha snapshot_config_sha tx rc=0
  expected_config_sha=$(jq -r --arg path '/etc/relay-manager-xray/config.json' '
    [.owned_files[]? | select(.path==$path) | .sha256][0] // empty
  ' "$RM_STATE_FILE")

  rm_capture_output tx tx_begin "$type" || return $?

  if [[ -n $expected_config_sha ]]; then
    tx_snapshot_file "$tx" "$RM_XRAY_CONFIG" || {
      tx_rollback "$tx" 'managed config snapshot failed before state-only apply' || true
      return "$RM_RC_PRECONDITION"
    }
    snapshot_config_sha=$(jq -r --arg dest "$RM_XRAY_CONFIG" '
      [.files[]|select(.destination==$dest)|.old_sha256][0] // empty
    ' "$(tx_file "$tx")")
    if [[ $snapshot_config_sha != "$expected_config_sha" ]]; then
      tx_rollback "$tx" 'managed config drifted before state-only apply' || true
      rm_error "受管 Xray 配置在状态更新前发生漂移。expected=$expected_config_sha actual=$snapshot_config_sha"
      return "$RM_RC_PRECONDITION"
    fi
  fi

  tx_stage_file "$tx" "$candidate" "$RM_STATE_FILE" 0600 root:root || {
    tx_rollback "$tx" 'state stage failed' || true
    return "$RM_RC_PRECONDITION"
  }

  tx_apply "$tx" || {
    rc=$?
    tx_rollback "$tx" 'state-only apply failed' || true
    return "$rc"
  }
  tx_commit "$tx"
}

node_apply_candidate_state() {
  local candidate=$1 type=${2:-node-change} confirm=${3:-true} service_mode=${4:-normal}
  [[ $confirm == true || $confirm == false ]] || return "$RM_RC_PRECONDITION"
  [[ $service_mode == normal || $service_mode == preserve ]] || return "$RM_RC_PRECONDITION"
  node_candidate_validate_ids "$candidate" || return $?
  node_candidate_validate_bindings "$candidate" || return $?
  node_assert_managed_config_not_drifted || return $?

  local tmpdir config core tx rc=0 enabled_count autostart was_active=false cfgsha c2 expected_config_sha snapshot_config_sha
  expected_config_sha=$(jq -r --arg path '/etc/relay-manager-xray/config.json' '
    [.owned_files[]? | select(.path==$path) | .sha256][0] // empty
  ' "$RM_STATE_FILE")
  tmpdir=$(rm_safe_tmpdir) || return $?
  config="$tmpdir/config.json"
  xray_render_state_config "$candidate" "$config" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  enabled_count=$(jq '[.nodes[]|select((if has("enabled") then .enabled else true end)==true)]|length' "$candidate")
  core=$(xray_current_binary)

  if ((enabled_count>0)); then
    xray_core_installed "$(xray_default_version)" || {
      rm_error '请先安装受管 Xray 核心'
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    }
    [[ -f $RM_XRAY_SERVICE_FILE ]] || {
      rm_error '受管 Xray systemd 服务尚未安装；请先执行 core install。'
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    }
    xray_test_config "$config" "$core" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    xray_ensure_user || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    node_address_family_preflight_candidate "$candidate" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    node_port_preflight_candidate "$candidate" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  fi

  if [[ $confirm == true && ${RM_TEST_MODE} != 1 ]]; then
    node_print_change_summary "$candidate" "$type"
    rm_confirm '确认应用上述变更?' || { rm -rf "$tmpdir"; return "$RM_RC_CANCEL"; }
    ((enabled_count==0)) || node_port_preflight_candidate "$candidate" || {
      rc=$?
      rm -rf "$tmpdir"
      return "$rc"
    }
  fi

  rm_service_is_active "$RM_XRAY_SERVICE" && was_active=true || true
  cfgsha=$(rm_sha256_file "$config")
  c2=$(mktemp "$tmpdir/state.XXXX") || { rm -rf "$tmpdir"; return "$RM_RC_INTERNAL"; }
  jq --arg cfgsha "$cfgsha" '
    .owned_files = ([.owned_files[]|select(.path!="/etc/relay-manager-xray/config.json")] +
      [{path:"/etc/relay-manager-xray/config.json",sha256:$cfgsha}])
  ' "$candidate" >"$c2"
  mv "$c2" "$candidate"

  rm_capture_output tx tx_begin "$type" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  tx_record_service "$tx" "$RM_XRAY_SERVICE" || true
  tx_stage_file "$tx" "$candidate" "$RM_STATE_FILE" 0600 root:root || {
    tx_rollback "$tx" 'state stage failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  }
  tx_stage_file "$tx" "$config" "$RM_XRAY_CONFIG" 0640 root:rm-xray || {
    tx_rollback "$tx" 'config stage failed' || true
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  }
  if [[ -n $expected_config_sha ]]; then
    snapshot_config_sha=$(jq -r --arg dest "$RM_XRAY_CONFIG" '
      [.files[] | select(.destination==$dest) | .old_sha256][0] // empty
    ' "$(tx_file "$tx")")
    if [[ $snapshot_config_sha != "$expected_config_sha" ]]; then
      tx_rollback "$tx" 'managed config changed before transaction snapshot' || true
      rm_error "受管 Xray 配置在计划与事务快照之间发生变化。expected=$expected_config_sha snapshot=$snapshot_config_sha"
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    fi
  fi
  tx_apply "$tx" || {
    rc=$?
    tx_rollback "$tx" 'apply failed' || true
    rm -rf "$tmpdir"
    return "$rc"
  }

  if ((enabled_count>0)); then
    if ! xray_test_config_as_service_user "$RM_XRAY_CONFIG" "$core"; then
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'rm-xray config validation failed' || rc=$?
      [[ $was_active == true ]] && rm_systemctl restart "$RM_XRAY_SERVICE" || true
      rm -rf "$tmpdir"
      return "$rc"
    fi
    autostart=$(jq -r '[.nodes[]|select((if has("enabled") then .enabled else true end)==true)] |
      if length==0 then true else (if .[0]|has("autostart") then .[0].autostart else true end) end' "$candidate")
    if [[ $service_mode == normal || $was_active == true ]]; then
      tx_mark_service_changed "$tx" "$RM_XRAY_SERVICE" || true
      if ! xray_service_enable_start "$autostart"; then
        rc=$RM_RC_APPLY_ROLLED_BACK
        tx_rollback "$tx" 'Xray service start failed' || rc=$?
        [[ $was_active == true ]] && rm_systemctl restart "$RM_XRAY_SERVICE" || true
        rm -rf "$tmpdir"
        return "$rc"
      fi
    fi
  elif [[ $service_mode == normal || $was_active == true ]]; then
    tx_mark_service_changed "$tx" "$RM_XRAY_SERVICE" || true
    rm_systemctl disable "$RM_XRAY_SERVICE" || {
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'Xray service disable failed' || rc=$?
      rm -rf "$tmpdir"
      return "$rc"
    }
    rm_systemctl stop "$RM_XRAY_SERVICE" || {
      rc=$RM_RC_APPLY_ROLLED_BACK
      tx_rollback "$tx" 'Xray service stop failed' || rc=$?
      rm -rf "$tmpdir"
      return "$rc"
    }
  fi

  tx_commit "$tx" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  rm -rf "$tmpdir"
}

node_target_safety_preflight_spec() {
  local spec=$1 mode=$2 nid target sni old_target='' old_sni='' probe summary
  [[ ${RM_TEST_MODE} == 1 ]] && return 0

  nid=$(jq -er '.node.node_id' "$spec") || return "$RM_RC_PRECONDITION"
  target=$(jq -er '.node.target' "$spec") || return "$RM_RC_PRECONDITION"
  sni=$(jq -er '.node.sni' "$spec") || return "$RM_RC_PRECONDITION"

  if [[ $mode == upsert ]] && [[ -f $RM_STATE_FILE ]]; then
    old_target=$(jq -r --arg nid "$nid" '.nodes[]|select(.node_id==$nid)|.target // empty' "$RM_STATE_FILE")
    old_sni=$(jq -r --arg nid "$nid" '.nodes[]|select(.node_id==$nid)|.sni // empty' "$RM_STATE_FILE")
    [[ $target == "$old_target" && $sni == "$old_sni" ]] && return 0
  fi

  declare -F target_probe >/dev/null 2>&1 || {
    rm_error 'Target 安全探测模块不可用，拒绝创建/切换 REALITY Target'
    return "$RM_RC_PRECONDITION"
  }

  probe=$(target_probe "$target" "$sni") || return $?
  if jq -e '.recommendation_eligible==true' <<<"$probe" >/dev/null; then
    rm_info "Target 安全门槛通过: $target / $sni"
    return 0
  fi

  summary=$(jq -c '{
    status,
    recommendation_eligible,
    recommendation_reason,
    abuse_risk:(.abuse_risk.status//"unverified"),
    catalog_recommendable:(.catalog_policy.recommendable//false)
  }' <<<"$probe")
  rm_error "Target 未通过防偷跑安全门槛，拒绝应用: $summary"
  return "$RM_RC_PRECONDITION"
}

node_create_or_replace_spec() {
  local input=$1 mode=${2:-create} tmpdir spec candidate rc
  rm_require_root || return $?
  xray_check_external_conflict || return $?
  [[ $mode == create || $mode == upsert ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  tmpdir=$(rm_safe_tmpdir) || return $?
  spec="$tmpdir/spec.json"
  candidate="$tmpdir/state.json"
  if [[ $mode == upsert ]]; then
    node_enrich_upsert_input "$input" "$tmpdir/enriched.json" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
    input="$tmpdir/enriched.json"
  fi
  node_prepare_spec "$input" "$spec" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_target_safety_preflight_spec "$spec" "$mode" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_candidate_from_spec "$spec" "$candidate" "$mode" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  node_apply_candidate_state "$candidate" "node-$mode" || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }

  if [[ $mode == upsert ]] && declare -F export_invalidate_upstream >/dev/null 2>&1; then
    local export_upid
    while IFS= read -r export_upid; do
      [[ -n $export_upid ]] && export_invalidate_upstream "$export_upid" || true
    done < <(jq -r '.upstreams[].upstream_id' "$spec")
  fi

  jq --argjson invalidated "$([[ $mode == upsert ]] && printf true || printf false)" \
    '{node_id:.node.node_id,upstream_ids:[.upstreams[].upstream_id],exports_invalidated:$invalidated}' "$spec"
  rm -rf "$tmpdir"
}

node_show() {
  local nid=$1
  state_init >/dev/null
  state_get_node "$nid"
}

node_delete() {
  local nid=$1 candidate tmpdir upids rc
  rm_require_root || return $?
  state_init >/dev/null
  state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  upids=$(jq -r --arg nid "$nid" '.upstreams[]|select(.node_id==$nid)|.upstream_id' "$RM_STATE_FILE")
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg nid "$nid" '
    .nodes=[.nodes[]|select(.node_id!=$nid)]
    | .upstreams=[.upstreams[]|select(.node_id!=$nid)]
    | .config_revision+=1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" node-delete || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  if declare -F export_invalidate_upstream >/dev/null 2>&1; then
    local up
    while IFS= read -r up; do [[ -n $up ]] && export_invalidate_upstream "$up" || true; done <<<"$upids"
  fi
  rm -rf "$tmpdir"
}

node_set_enabled() {
  local nid=$1 val=$2 tmpdir candidate rc
  [[ $val == true || $val == false ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg nid "$nid" --argjson val "$val" '
    (.nodes[]|select(.node_id==$nid)).enabled=$val | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" node-enable || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  rm -rf "$tmpdir"
}

node_rotate_reality_keys() {
  local nid=$1 tmpdir candidate kp priv pass upids rc
  rm_require_root || return $?
  state_init >/dev/null
  state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  kp=$("$RM_PROTOCOL_VR" generate_keypair "$(xray_current_binary)") || return $?
  priv=$(jq -er .private_key <<<"$kp") || return "$RM_RC_PRECONDITION"
  pass=$(jq -er .password <<<"$kp") || return "$RM_RC_PRECONDITION"
  upids=$(jq -r --arg nid "$nid" '.upstreams[]|select(.node_id==$nid)|.upstream_id' "$RM_STATE_FILE")
  printf 'REALITY 密钥轮换会立即影响该节点的全部线路机，成功后必须重新导出并更新线路端配置。\n' >&2
  printf '%s\n' "$upids" | sed '/^$/d;s/^/  - /' >&2

  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg nid "$nid" --arg priv "$priv" --arg pass "$pass" '
    (.nodes[]|select(.node_id==$nid)).reality.private_key=$priv
    | (.nodes[]|select(.node_id==$nid)).reality.password=$pass
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" node-reality-key-rotation || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }

  if declare -F export_invalidate_upstream >/dev/null 2>&1; then
    local up
    while IFS= read -r up; do [[ -n $up ]] && export_invalidate_upstream "$up" || true; done <<<"$upids"
  fi
  jq -n --arg node "$nid" --arg ids "$upids" '{
    status:"rotated",node_id:$node,
    affected_upstreams:($ids|split("\n")|map(select(length>0))),
    exports_invalidated:true,d4_evidence_requires_retest:true,
    server_private_key_exposed:false
  }'
  rm -rf "$tmpdir"
}

upstream_add_from_json() {
  local nid=$1 input=$2 tmpdir candidate obj validate_spec upid uuid xray i count addr norm t2 rc
  state_init >/dev/null
  state_get_node "$nid" >/dev/null || { rm_error '节点不存在'; return "$RM_RC_PRECONDITION"; }
  rm_json_valid "$input" || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  obj="$tmpdir/up.json"
  xray=$(xray_current_binary)
  upid=$(jq -r '.upstream_id//empty' "$input")
  [[ -n $upid ]] || upid=$(upstream_id_new)
  uuid=$(jq -r '.uuid//empty' "$input")
  [[ -n $uuid ]] || uuid=$("$RM_PROTOCOL_VR" generate_uuid "$xray")
  jq --arg id "$upid" --arg nid "$nid" --arg uuid "$uuid" --arg now "$(rm_now)" '
    . + {upstream_id:$id,node_id:$nid,uuid:$uuid,enabled:(if .enabled==null then true else .enabled end),
      source_addresses:(.source_addresses//[]),created_at:(.created_at//$now),updated_at:$now}
  ' "$input" >"$obj"

  count=$(jq '.source_addresses|length' "$obj")
  for ((i=0;i<count;i++)); do
    addr=$(jq -r ".source_addresses[$i]" "$obj")
    norm=$(rm_normalize_ip_or_cidr "$addr") || {
      rm_error "无效线路机来源: $addr"
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    }
    t2=$(mktemp "$tmpdir/up.XXXX") || { rm -rf "$tmpdir"; return "$RM_RC_INTERNAL"; }
    jq --argjson i "$i" --arg v "$norm" '.source_addresses[$i]=$v' "$obj" >"$t2"
    mv "$t2" "$obj"
  done
  [[ $upid =~ ^up-[A-Za-z0-9._-]{1,48}$ ]] || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  validate_spec="$tmpdir/validate-spec.json"
  jq --arg nid "$nid" --slurpfile u "$obj" '
    (.nodes[]|select(.node_id==$nid)) as $n | {node:$n,upstreams:$u}
  ' "$RM_STATE_FILE" >"$validate_spec" || {
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  }
  if ! "$RM_PROTOCOL_VR" validate "$validate_spec"; then
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  fi
  if jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)' "$RM_STATE_FILE" >/dev/null; then
    rm_error 'upstream_id 已存在'
    rm -rf "$tmpdir"
    return "$RM_RC_PRECONDITION"
  fi

  jq --slurpfile u "$obj" '.upstreams += $u | .config_revision+=1' "$RM_STATE_FILE" |
    jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-add || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  printf '%s\n' "$upid"
  rm -rf "$tmpdir"
}

upstream_show() {
  local upid=$1
  state_init >/dev/null
  state_get_upstream "$upid"
}

upstream_update_from_json() {
  local upid=$1 input=$2 source_mode=${3:-user} tmpdir obj candidate count i addr norm t2 rc name enabled
  [[ $source_mode == user || $source_mode == transition ]] || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || { rm_error '线路机不存在'; return "$RM_RC_PRECONDITION"; }
  rm_json_valid "$input" || return "$RM_RC_PRECONDITION"
  jq -e 'type=="object" and ((keys - ["name","note","source_addresses","enabled"])|length==0)' "$input" >/dev/null || {
    rm_error '线路机更新只允许 name/note/source_addresses/enabled'
    return "$RM_RC_PRECONDITION"
  }
  if [[ $source_mode == user ]] && jq -e 'has("source_addresses")' "$input" >/dev/null; then
    rm_error '已有线路机的来源地址必须使用 source-add/source-remove 分步变更，禁止一刀切替换。'
    return "$RM_RC_PRECONDITION"
  fi

  tmpdir=$(rm_safe_tmpdir) || return $?
  obj="$tmpdir/up.json"
  candidate="$tmpdir/state.json"
  jq --arg id "$upid" --slurpfile patch "$input" '
    (.upstreams[]|select(.upstream_id==$id)) * $patch[0] | .upstream_id=$id
  ' "$RM_STATE_FILE" >"$obj"
  name=$(jq -er '.name' "$obj") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$obj")
  rm_valid_name "$name" || { rm_error '线路机名称格式错误'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  [[ $enabled == true || $enabled == false ]] || { rm_error 'enabled 必须是布尔值'; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }

  count=$(jq '.source_addresses|length' "$obj")
  for ((i=0;i<count;i++)); do
    addr=$(jq -er ".source_addresses[$i]" "$obj") || { rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
    norm=$(rm_normalize_ip_or_cidr "$addr") || {
      rm_error "无效线路机来源: $addr"
      rm -rf "$tmpdir"
      return "$RM_RC_PRECONDITION"
    }
    t2=$(mktemp "$tmpdir/up.XXXX") || { rm -rf "$tmpdir"; return "$RM_RC_INTERNAL"; }
    jq --argjson i "$i" --arg v "$norm" '.source_addresses[$i]=$v' "$obj" >"$t2"
    mv "$t2" "$obj"
  done

  t2=$(mktemp "$tmpdir/up.unique.XXXX") || { rm -rf "$tmpdir"; return "$RM_RC_INTERNAL"; }
  jq '.source_addresses |= unique' "$obj" >"$t2"
  mv "$t2" "$obj"

  local runtime_changed export_changed
  runtime_changed=$(jq -r --arg id "$upid" --slurpfile obj "$obj" '
    (.upstreams[]|select(.upstream_id==$id)) as $old |
    ($old.enabled != $obj[0].enabled)
  ' "$RM_STATE_FILE")
  export_changed=$(jq -r --arg id "$upid" --slurpfile obj "$obj" '
    (.upstreams[]|select(.upstream_id==$id)) as $old |
    (($old.enabled != $obj[0].enabled) or ($old.name != $obj[0].name))
  ' "$RM_STATE_FILE")

  jq --arg id "$upid" --slurpfile obj "$obj" '
    .upstreams=[.upstreams[]|if .upstream_id==$id then $obj[0] else . end] | .config_revision+=1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"

  if [[ $runtime_changed == true ]]; then
    node_apply_candidate_state "$candidate" upstream-update || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  else
    node_apply_state_only_candidate "$candidate" upstream-metadata-update || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  fi

  if [[ $export_changed == true ]] && declare -F export_invalidate_upstream >/dev/null 2>&1; then
    export_invalidate_upstream "$upid" || true
  fi
  rm -rf "$tmpdir"
}

upstream_source_scope_json() {
  local input=$1 norm family prefix scope=single warning=''
  norm=$(rm_normalize_ip_or_cidr "$input") || {
    rm_error "无效线路机来源: $input"
    return "$RM_RC_PRECONDITION"
  }
  if [[ $norm == *:* ]]; then family=ipv6; else family=ipv4; fi
  if [[ $norm == */* ]]; then
    prefix=${norm##*/}
    scope=cidr
    if [[ $family == ipv4 ]]; then
      if ((10#$prefix == 0)); then
        scope=all
        warning='该来源等同全部 IPv4 地址，范围极大。'
      elif ((10#$prefix < 24)); then
        scope=broad
        warning='该 IPv4 CIDR 范围较大；建议优先使用线路机实际单地址。'
      fi
    else
      if ((10#$prefix == 0)); then
        scope=all
        warning='该来源等同全部 IPv6 地址，范围极大。'
      elif ((10#$prefix < 64)); then
        scope=broad
        warning='该 IPv6 CIDR 范围较大；建议优先使用线路机实际单地址。'
      fi
    fi
  fi
  jq -n --arg address "$norm" --arg family "$family" --arg scope "$scope" --arg warning "$warning" \
    '{address:$address,family:$family,scope:$scope,
      warning:(if $warning=="" then null else $warning end)}'
}

upstream_source_add() {
  local upid=$1 input=$2 normalized meta tmpdir patch rc
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || {
    rm_error '线路机不存在'
    return "$RM_RC_PRECONDITION"
  }
  meta=$(upstream_source_scope_json "$input") || return $?
  normalized=$(jq -r .address <<<"$meta")
  if jq -e --arg id "$upid" --arg addr "$normalized" '
    .upstreams[]|select(.upstream_id==$id)|.source_addresses[]?|select(.==$addr)
  ' "$RM_STATE_FILE" >/dev/null; then
    jq -n --arg up "$upid" --argjson meta "$meta" \
      '{status:"already_present",upstream_id:$up,source:$meta,
        restriction_implementation:"intent-only-until-stage-c"}'
    return 0
  fi

  tmpdir=$(rm_safe_tmpdir) || return $?
  patch="$tmpdir/source-add.json"
  jq --arg id "$upid" --arg addr "$normalized" '
    (.upstreams[]|select(.upstream_id==$id)|.source_addresses + [$addr] | unique) as $sources |
    {source_addresses:$sources}
  ' "$RM_STATE_FILE" >"$patch"
  upstream_update_from_json "$upid" "$patch" transition || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq -n --arg up "$upid" --argjson meta "$meta" \
    '{status:"added",upstream_id:$up,source:$meta,
      transition_guidance:"先保留旧来源并从新出口实际验证，确认后再移除旧来源。",
      restriction_implementation:"intent-only-until-stage-c"}'
  rm -rf "$tmpdir"
}

upstream_source_remove() {
  local upid=$1 input=$2 normalized tmpdir patch rc remaining
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || {
    rm_error '线路机不存在'
    return "$RM_RC_PRECONDITION"
  }
  normalized=$(rm_normalize_ip_or_cidr "$input") || {
    rm_error "无效线路机来源: $input"
    return "$RM_RC_PRECONDITION"
  }

  if ! jq -e --arg id "$upid" --arg addr "$normalized" '
    .upstreams[]|select(.upstream_id==$id)|.source_addresses[]?|select(.==$addr)
  ' "$RM_STATE_FILE" >/dev/null; then
    jq -n --arg up "$upid" --arg addr "$normalized" \
      '{status:"already_absent",upstream_id:$up,address:$addr,
        restriction_implementation:"intent-only-until-stage-c"}'
    return 0
  fi

  tmpdir=$(rm_safe_tmpdir) || return $?
  patch="$tmpdir/source-remove.json"
  jq --arg id "$upid" --arg addr "$normalized" '
    (.upstreams[]|select(.upstream_id==$id)|[.source_addresses[]|select(.!=$addr)] | unique) as $sources |
    {source_addresses:$sources}
  ' "$RM_STATE_FILE" >"$patch"
  upstream_update_from_json "$upid" "$patch" transition || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  remaining=$(jq -r --arg id "$upid" '.upstreams[]|select(.upstream_id==$id)|.source_addresses|length' "$RM_STATE_FILE")
  jq -n --arg up "$upid" --arg addr "$normalized" --argjson remaining "$remaining" \
    '{status:"removed",upstream_id:$up,address:$addr,remaining_sources:$remaining,
      warning:(if $remaining==0 then "来源列表已为空；白名单模式下应保持默认拒绝，阶段 C 不得自动退化为公网开放。" else null end),
      restriction_implementation:"intent-only-until-stage-c"}'
  rm -rf "$tmpdir"
}

upstream_set_enabled() {
  local upid=$1 val=$2 tmpdir patch rc
  [[ $val == true || $val == false ]] || return "$RM_RC_PRECONDITION"
  tmpdir=$(rm_safe_tmpdir) || return $?
  patch="$tmpdir/patch.json"
  jq -n --argjson enabled "$val" '{enabled:$enabled}' >"$patch"
  upstream_update_from_json "$upid" "$patch"
  rc=$?
  rm -rf "$tmpdir"
  return "$rc"
}

upstream_delete() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || { rm_error '线路机不存在'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg id "$upid" '
    .upstreams=[.upstreams[]|select(.upstream_id!=$id)] | .config_revision+=1
  ' "$RM_STATE_FILE" | jq "$_node_sources_rebuild_filter" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-delete || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream >/dev/null 2>&1 && export_invalidate_upstream "$upid" || true
  rm -rf "$tmpdir"
}

upstream_rotation_prepare() {
  local upid=$1 ttl=${2:-86400} tmpdir candidate uuid now deadline rc
  [[ $ttl =~ ^[0-9]+$ ]] && ((10#$ttl >= 300 && 10#$ttl <= 604800)) || {
    rm_error 'UUID 并行轮换有效期必须为 300-604800 秒'
    return "$RM_RC_PRECONDITION"
  }
  ttl=$((10#$ttl))
  state_init >/dev/null
  state_get_upstream "$upid" >/dev/null || { rm_error '线路机不存在'; return "$RM_RC_PRECONDITION"; }
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null &&
    { rm_error '已有待完成 UUID 轮换'; return "$RM_RC_PRECONDITION"; }

  uuid=$("$RM_PROTOCOL_VR" generate_uuid "$(xray_current_binary)") || return $?
  now=$(rm_epoch)
  deadline=$((now+ttl))
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg id "$upid" --arg uuid "$uuid" --argjson deadline "$deadline" --arg now "$(rm_now)" '
    (.upstreams[]|select(.upstream_id==$id)) |=
      (.pending_uuid=$uuid | .rotation={status:"parallel",deadline_epoch:$deadline,prepared_at:$now})
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-prepare || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  jq -n --arg up "$upid" --arg uuid "$uuid" --argjson deadline "$deadline"     '{upstream_id:$up,pending_uuid:$uuid,deadline_epoch:$deadline,status:"parallel",
      note:"在截止时间前切换线路端；确认新 UUID 可用后执行 rotate-commit，否则到期自动撤销新 UUID。"}'
  rm -rf "$tmpdir"
}

upstream_rotation_commit() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null ||
    { rm_error '没有待提交 UUID'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg id "$upid" '
    (.upstreams[]|select(.upstream_id==$id)) |= (.uuid=.pending_uuid|del(.pending_uuid,.rotation))
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-commit || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream >/dev/null 2>&1 && export_invalidate_upstream "$upid" || true
  rm -rf "$tmpdir"
}

upstream_rotation_cancel() {
  local upid=$1 tmpdir candidate rc
  state_init >/dev/null
  jq -e --arg id "$upid" '.upstreams[]|select(.upstream_id==$id and (.pending_uuid//"")!="")' "$RM_STATE_FILE" >/dev/null ||
    { rm_error '没有待取消 UUID'; return "$RM_RC_PRECONDITION"; }
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --arg id "$upid" '
    (.upstreams[]|select(.upstream_id==$id)) |= del(.pending_uuid,.rotation)
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotate-cancel || { rc=$?; rm -rf "$tmpdir"; return "$rc"; }
  declare -F export_invalidate_upstream_mode >/dev/null 2>&1 && export_invalidate_upstream_mode "$upid" pending || true
  rm -rf "$tmpdir"
}

upstream_rotation_reconcile_expired() {
  state_init >/dev/null
  local now tmpdir candidate count ids rc=0
  now=$(rm_epoch)
  count=$(jq --argjson now "$now" '
    [.upstreams[]|select((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now)]|length
  ' "$RM_STATE_FILE")
  ((count>0)) || { jq -n '{status:"normal",expired_rotations:0}'; return 0; }
  ids=$(jq -r --argjson now "$now" '
    .upstreams[]|select((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now)|.upstream_id
  ' "$RM_STATE_FILE")
  tmpdir=$(rm_safe_tmpdir) || return $?
  candidate="$tmpdir/state.json"
  jq --argjson now "$now" '
    .upstreams |= map(
      if ((.pending_uuid//"")!="" and (.rotation.deadline_epoch//0) <= $now)
      then del(.pending_uuid,.rotation) else . end
    )
    | .config_revision+=1
  ' "$RM_STATE_FILE" >"$candidate"
  node_apply_candidate_state "$candidate" upstream-rotation-expire false preserve || {
    rc=$?
    rm -rf "$tmpdir"
    return "$rc"
  }
  if declare -F export_invalidate_upstream_mode >/dev/null 2>&1; then
    local id
    while IFS= read -r id; do [[ -n $id ]] && export_invalidate_upstream_mode "$id" pending || true; done <<<"$ids"
  fi
  jq -n --argjson count "$count" --arg ids "$ids"     '{status:"normal",expired_rotations:$count,upstream_ids:($ids|split("\n")|map(select(length>0)))}'
  rm -rf "$tmpdir"
}
