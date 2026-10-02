#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$BASE_DIR/lib/fail2ban.sh"
source "$BASE_DIR/lib/firewall.sh"
source "$BASE_DIR/lib/export.sh"
source "$BASE_DIR/lib/target.sh"

status_obj() {
  jq -n --arg status "$1" --arg check "$2" --arg detail "${3:-}"     '{status:$status,check:$check,detail:(if $detail=="" then null else $detail end)}'
}

diag_d1() {
  local items='[]' s
  if state_validate 2>/dev/null; then s=$(status_obj normal state-schema); else s=$(status_obj abnormal state-schema 'state.json 无效或 schema 不匹配'); fi
  items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")

  if [[ -f $RM_XRAY_CONFIG ]]; then
    if [[ -x $(xray_current_binary) ]]; then
      if xray_test_config "$RM_XRAY_CONFIG" >/dev/null 2>&1; then s=$(status_obj normal xray-config); else s=$(status_obj abnormal xray-config '核心配置测试失败'); fi
    else
      s=$(status_obj unverified xray-config '受管核心不存在')
    fi
  else
    s=$(status_obj not_applicable xray-config '尚无运行配置')
  fi
  items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")

  local p mode owner group expected_mode expected_group
  for p in "$RM_STATE_FILE" "$RM_XRAY_CONFIG"; do
    [[ -e $p ]] || continue
    mode=$(stat -c '%a' "$p")
    owner=$(stat -c '%U' "$p" 2>/dev/null || true)
    group=$(stat -c '%G' "$p" 2>/dev/null || true)
    if [[ $p == "$RM_STATE_FILE" ]]; then expected_mode=600; expected_group=root; else expected_mode=640; expected_group=rm-xray; fi
    if [[ ${RM_TEST_MODE} == 1 ]]; then
      [[ $mode == "$expected_mode" ]] && s=$(status_obj normal permissions "$p mode=$mode (测试模式未验证真实 owner/group)") || s=$(status_obj abnormal permissions "$p mode=$mode")
    elif [[ $mode == "$expected_mode" && $owner == root && $group == "$expected_group" ]]; then
      s=$(status_obj normal permissions "$p mode=$mode owner=$owner group=$group")
    else
      s=$(status_obj abnormal permissions "$p mode=$mode owner=$owner group=$group expected=$expected_mode/root:$expected_group")
    fi
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  done
  printf '%s\n' "$items"
}

diag_d2() {
  local items='[]' s mainpid user nid port enabled lines
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    s=$(status_obj unverified service '测试模式未读取真实 systemd')
  elif systemctl is-active --quiet "$RM_XRAY_SERVICE" 2>/dev/null; then
    s=$(status_obj normal service "$RM_XRAY_SERVICE active")
  elif jq -e '[.nodes[]|select((.enabled//true)==true)]|length>0' "$RM_STATE_FILE" >/dev/null; then
    s=$(status_obj abnormal service "$RM_XRAY_SERVICE inactive")
  else
    s=$(status_obj not_applicable service '无启用节点')
  fi
  items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")

  if [[ ${RM_TEST_MODE} != 1 ]] && systemctl is-active --quiet "$RM_XRAY_SERVICE" 2>/dev/null; then
    mainpid=$(systemctl show -p MainPID --value "$RM_XRAY_SERVICE" 2>/dev/null || printf 0)
    user=$(ps -o user= -p "$mainpid" 2>/dev/null | awk '{$1=$1;print}' || true)
    if [[ $user == rm-xray ]]; then s=$(status_obj normal process-user "pid=$mainpid user=$user"); else s=$(status_obj abnormal process-user "pid=$mainpid user=$user expected=rm-xray"); fi
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  fi

  while IFS=$'\t' read -r nid port enabled; do
    [[ $enabled == true ]] || continue
    if ! rm_have ss; then
      s=$(status_obj unverified listener "$nid:$port 缺少 ss")
    else
      lines=$(ss -H -lntp "sport = :$port" 2>/dev/null || true)
      if [[ -n $lines ]]; then s=$(status_obj normal listener "$nid:$port"); else s=$(status_obj abnormal listener "$nid:$port 未监听"); fi
    fi
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  done < <(jq -r '.nodes[]|[.node_id,(.listen_port|tostring),((.enabled//true)|tostring)]|@tsv' "$RM_STATE_FILE")
  printf '%s\n' "$items"
}

diag_d3() {
  local items='[]' x nid target sni result st detail fw
  while IFS=$'\t' read -r nid target sni; do
    [[ -n $nid ]] || continue
    result=$(target_probe "$target" "$sni")
    st=$(jq -r '.status' <<<"$result")
    detail=$(jq -c '{target,sni,resolved_address,latency_ms,checks,reason,warning}' <<<"$result")
    case "$st" in
      suitable_measured) x=$(status_obj normal target-probe "$nid $detail");;
      failed) x=$(status_obj abnormal target-probe "$nid $detail");;
      *) x=$(status_obj unverified target-probe "$nid $detail");;
    esac
    items=$(jq -c --argjson x "$x" '.+[$x]' <<<"$items")
  done < <(jq -r '.nodes[]|select((.enabled//true)==true)|[.node_id,.target,.sni]|@tsv' "$RM_STATE_FILE")

  fw=$(fw_status_json)
  if jq -e '.installed==true and .active==true' <<<"$fw" >/dev/null; then
    x=$(status_obj unverified firewall-isolation 'UFW 已启用；来源隔离效果必须由阶段 C 的白名单/非白名单真实连接验证')
  else
    x=$(status_obj unverified firewall-isolation '本机 UFW 未实施或未启用；节点来源限制不能据此宣称已生效')
  fi
  items=$(jq -c --argjson x "$x" '.+[$x]' <<<"$items")
  printf '%s\n' "$items"
}

diag_connection_fingerprint() {
  local node=$1 upstream=$2
  jq -c --arg node "$node" --arg up "$upstream" '
    (.nodes[]|select(.node_id==$node)) as $n |
    (.upstreams[]|select(.upstream_id==$up and .node_id==$node)) as $u |
    {node_id:$n.node_id,address:$n.public_host,port:$n.public_port,target:$n.target,sni:$n.sni,flow:$n.flow,
     password:$n.reality.password,short_id:$n.reality.short_id,uuid:$u.uuid}
  ' "$RM_STATE_FILE" | sha256sum | awk '{print $1}'
}

diag_d4() {
  local items='[]' node up ev expected got s
  while IFS=$'\t' read -r node up; do
    [[ -n $up ]] || continue
    ev="$RM_VAR_DIR/evidence/d4/$up.json"
    expected=$(diag_connection_fingerprint "$node" "$up" 2>/dev/null || true)
    if [[ -f $ev ]] && jq -e '.result=="pass" and (.tested_at|type=="string") and (.fingerprint|type=="string")' "$ev" >/dev/null 2>&1; then
      got=$(jq -r .fingerprint "$ev")
      if [[ -n $expected && $got == "$expected" ]]; then
        s=$(jq -n --arg node "$node" --arg up "$up" --slurpfile e "$ev" '{status:"normal",check:"line-end-to-end",node_id:$node,upstream_id:$up,evidence:$e[0]}')
      else
        s=$(jq -n --arg node "$node" --arg up "$up" '{status:"unverified",check:"line-end-to-end",node_id:$node,upstream_id:$up,detail:"节点或凭据已变化，旧 D4 证据失效，需要重新实测"}')
      fi
    else
      s=$(jq -n --arg node "$node" --arg up "$up" '{status:"unverified",check:"line-end-to-end",node_id:$node,upstream_id:$up,detail:"需要从指定线路 VPS 建立真实 REALITY 连接并执行代理请求；本机监听不能代替 T25"}')
    fi
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  done < <(jq -r '.upstreams[]|select((.enabled//true)==true)|[.node_id,.upstream_id]|@tsv' "$RM_STATE_FILE")
  printf '%s\n' "$items"
}

diag_record_d4() {
  local node=$1 upstream=$2 exit_ip=$3 panel_version=$4 core_version=$5 route_note=${6:-}
  rm_require_root || return $?
  rm_tty_available || return "$RM_RC_PRECONDITION"
  state_init >/dev/null
  jq -e --arg node "$node" --arg up "$upstream" '.upstreams[]|select(.upstream_id==$up and .node_id==$node and ((.enabled//true)==true))' "$RM_STATE_FILE" >/dev/null || {
    rm_error '线路机不存在、未启用或不属于该节点'; return "$RM_RC_PRECONDITION";
  }
  local ip
  ip=$(rm_normalize_ip_or_cidr "$exit_ip" 2>/dev/null || true)
  [[ -n $ip && $ip != */* ]] || { rm_error '出口地址必须是单个 IPv4/IPv6 地址'; return "$RM_RC_PRECONDITION"; }
  [[ -n $panel_version && -n $core_version ]] || { rm_error '必须记录 3x-ui 与线路端 Xray 核心版本'; return "$RM_RC_PRECONDITION"; }

  local ans
  rm_read_tty ans '确认你已在线路 VPS 实际完成 REALITY 认证、代理请求并核对落地出口。输入 RECORD: '
  [[ $ans == RECORD ]] || return "$RM_RC_CANCEL"

  local dir fp
  dir="$RM_VAR_DIR/evidence/d4"
  rm_mkdir_secure 0700 "$dir"
  fp=$(diag_connection_fingerprint "$node" "$upstream")
  jq -n --arg node "$node" --arg up "$upstream" --arg ip "$ip" --arg panel "$panel_version" --arg core "$core_version"     --arg route "$route_note" --arg fp "$fp" --arg at "$(rm_now)"     '{result:"pass",node_id:$node,upstream_id:$up,exit_ip:$ip,panel_version:$panel,line_core_version:$core,
      route_note:(if $route=="" then null else $route end),fingerprint:$fp,tested_at:$at,method:"manual real VPS attestation"}' >"$dir/$upstream.json"
  chmod 0600 "$dir/$upstream.json"
}

doctor_all() {
  state_init >/dev/null
  jq -n --arg generated "$(rm_now)" --argjson d1 "$(diag_d1)" --argjson d2 "$(diag_d2)" --argjson d3 "$(diag_d3)" --argjson d4 "$(diag_d4)"     '{generated_at:$generated,levels:{D1_config:$d1,D2_local:$d2,D3_network:$d3,D4_line:$d4}}'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-doctor}" in
    doctor) doctor_all;;
    record-d4) shift; diag_record_d4 "$@";;
    *) printf 'Usage: diagnostics.sh [doctor|record-d4 NODE UPSTREAM EXIT_IP PANEL_VERSION CORE_VERSION [ROUTE_NOTE]]\n' >&2; exit 10;;
  esac
fi
