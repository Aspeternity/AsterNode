#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$BASE_DIR/lib/fail2ban.sh"
source "$BASE_DIR/lib/firewall.sh"
source "$BASE_DIR/lib/export.sh"

status_obj() { jq -n --arg status "$1" --arg check "$2" --arg detail "${3:-}" '{status:$status,check:$check,detail:(if $detail=="" then null else $detail end)}'; }

diag_d1() {
  local items='[]' s
  if state_validate 2>/dev/null; then s=$(status_obj normal state-schema); else s=$(status_obj abnormal state-schema 'state.json 无效或 schema 不匹配'); fi; items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  if [[ -f $RM_XRAY_CONFIG ]]; then
    if [[ -x $(xray_current_binary) ]]; then if xray_test_config "$RM_XRAY_CONFIG" >/dev/null 2>&1; then s=$(status_obj normal xray-config); else s=$(status_obj abnormal xray-config '核心配置测试失败'); fi
    else s=$(status_obj unverified xray-config '受管核心不存在'); fi
  else s=$(status_obj not_applicable xray-config '尚无运行配置'); fi; items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  local p mode actual
  for p in "$RM_STATE_FILE" "$RM_XRAY_CONFIG"; do
    [[ -e $p ]] || continue; mode=$(stat -c '%a' "$p"); actual=$(stat -c '%U:%G' "$p" 2>/dev/null || true)
    case "$p" in "$RM_STATE_FILE") [[ $mode == 600 ]] && s=$(status_obj normal permissions "$p mode=$mode owner=$actual") || s=$(status_obj abnormal permissions "$p mode=$mode owner=$actual");; *) [[ $mode == 640 ]] && s=$(status_obj normal permissions "$p mode=$mode owner=$actual") || s=$(status_obj abnormal permissions "$p mode=$mode owner=$actual");; esac
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  done
  printf '%s\n' "$items"
}

diag_d2() {
  local items='[]' s nid port enabled
  if [[ ${RM_TEST_MODE} == 1 ]]; then s=$(status_obj unverified service '测试模式未读取真实 systemd');
  elif systemctl is-active --quiet "$RM_XRAY_SERVICE" 2>/dev/null; then s=$(status_obj normal service "$RM_XRAY_SERVICE active"); else
    if jq -e '[.nodes[]|select((.enabled//true)==true)]|length>0' "$RM_STATE_FILE" >/dev/null; then s=$(status_obj abnormal service "$RM_XRAY_SERVICE inactive"); else s=$(status_obj not_applicable service '无启用节点'); fi
  fi; items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  while IFS=$'\t' read -r nid port enabled; do
    [[ $enabled == true ]] || continue
    if ! rm_have ss; then s=$(status_obj unverified listener "$nid:$port 缺少 ss");
    elif ss -H -lnt "sport = :$port" 2>/dev/null | grep -q .; then s=$(status_obj normal listener "$nid:$port"); else s=$(status_obj abnormal listener "$nid:$port 未监听"); fi
    items=$(jq -c --argjson x "$s" '.+[$x]' <<<"$items")
  done < <(jq -r '.nodes[]|[.node_id,(.listen_port|tostring),((.enabled//true)|tostring)]|@tsv' "$RM_STATE_FILE")
  printf '%s\n' "$items"
}

diag_target_one() {
  local nid=$1 target=$2 sni=$3 host port conn timeout_cmd result status=unverified detail
  if [[ $target == \[*\]:* ]]; then host=${target#\[}; host=${host%%\]*}; port=${target##*:}; else host=${target%:*}; port=${target##*:}; fi
  if ! getent ahosts "$host" >/dev/null 2>&1; then jq -n --arg nid "$nid" --arg target "$target" '{status:"abnormal",check:"target-dns",node_id:$nid,target:$target,detail:"DNS 解析失败"}'; return; fi
  if ! rm_have openssl || ! rm_have timeout; then jq -n --arg nid "$nid" --arg target "$target" '{status:"unverified",check:"target-tls",node_id:$nid,target:$target,detail:"缺少 openssl/timeout"}'; return; fi
  set +e; result=$(timeout 6 openssl s_client -connect "$target" -servername "$sni" -tls1_3 -brief </dev/null 2>&1); local rc=$?; set -e
  if ((rc==0)) && grep -Eq 'Protocol version: TLSv1\.3|Protocol.*TLSv1\.3' <<<"$result"; then status=normal; detail='TLS 1.3 握手成功'; else status=abnormal; detail="TLS 1.3 握手失败/超时: ${result:0:300}"; fi
  jq -n --arg status "$status" --arg nid "$nid" --arg target "$target" --arg detail "$detail" '{status:$status,check:"target-tls",node_id:$nid,target:$target,detail:$detail}'
}

diag_d3() {
  local items='[]' x nid target sni fw
  while IFS=$'\t' read -r nid target sni; do [[ -n $nid ]] || continue; x=$(diag_target_one "$nid" "$target" "$sni"); items=$(jq -c --argjson x "$x" '.+[$x]' <<<"$items"); done < <(jq -r '.nodes[]|select((.enabled//true)==true)|[.node_id,.target,.sni]|@tsv' "$RM_STATE_FILE")
  fw=$(fw_status_json); if jq -e '.installed==true and .active==true' <<<"$fw" >/dev/null; then x=$(status_obj unverified firewall-isolation 'UFW 已启用；来源隔离需线路端/非白名单真实连接对照'); else x=$(status_obj unverified firewall-isolation '本机 UFW 未实施或未启用'); fi
  items=$(jq -c --argjson x "$x" '.+[$x]' <<<"$items")
  printf '%s\n' "$items"
}

diag_d4() {
  local ev="$RM_VAR_DIR/evidence/d4.json"
  if [[ -f $ev ]] && jq -e '.result=="pass" and (.tested_at|type=="string")' "$ev" >/dev/null 2>&1; then jq -n --slurpfile e "$ev" '{status:"normal",check:"line-end-to-end",evidence:$e[0]}';
  else jq -n '{status:"unverified",check:"line-end-to-end",detail:"需要从指定线路 VPS 建立真实 REALITY 连接并执行代理请求；本机监听不能代替 T25。"}'; fi
}

diag_record_d4() {
  local node=$1 upstream=$2 exit_ip=$3 panel_version=$4 core_version=$5
  rm_tty_available || return "$RM_RC_PRECONDITION"
  local ans; rm_read_tty ans '确认你已在线路 VPS 实际完成 REALITY 认证和代理请求，并核对出口 IP。输入 RECORD: '; [[ $ans == RECORD ]] || return "$RM_RC_CANCEL"
  rm_mkdir_secure 0700 "$RM_VAR_DIR/evidence"
  jq -n --arg node "$node" --arg up "$upstream" --arg ip "$exit_ip" --arg panel "$panel_version" --arg core "$core_version" --arg at "$(rm_now)" '{result:"pass",node_id:$node,upstream_id:$up,exit_ip:$ip,panel_version:$panel,line_core_version:$core,tested_at:$at,method:"manual real VPS attestation"}' >"$RM_VAR_DIR/evidence/d4.json"
  chmod 0600 "$RM_VAR_DIR/evidence/d4.json"
}

doctor_all() {
  state_init >/dev/null
  jq -n --arg generated "$(rm_now)" --argjson d1 "$(diag_d1)" --argjson d2 "$(diag_d2)" --argjson d3 "$(diag_d3)" --argjson d4 "$(diag_d4)" '{generated_at:$generated,levels:{D1_config:$d1,D2_local:$d2,D3_network:$d3,D4_line:$d4}}'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case "${1:-doctor}" in doctor) doctor_all;; record-d4) shift; diag_record_d4 "$@";; *) printf 'Usage: diagnostics.sh [doctor|record-d4 ...]\n' >&2; exit 10;; esac
fi
