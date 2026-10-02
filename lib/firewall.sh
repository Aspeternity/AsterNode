#!/usr/bin/env bash
# Conservative UFW adapter. It never resets UFW and never edits external rules.
# shellcheck source=lib/transaction.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"
# shellcheck source=lib/system.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/system.sh"

fw_ufw() {
  if [[ ${RM_TEST_MODE} == 1 ]]; then
    [[ -n ${RM_UFW_LOG:-} ]] && printf '%q ' "$@" >>"$RM_UFW_LOG" && printf '\n' >>"$RM_UFW_LOG"
    return 0
  fi
  ufw "$@"
}

fw_ufw_status_text() {
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} && -f $RM_UFW_STATUS_FILE ]]; then cat "$RM_UFW_STATUS_FILE"; else ufw status verbose 2>/dev/null; fi
}

fw_status_json() {
  local installed=false active=false default_in=unknown text complex=false reason=''
  rm_have ufw && installed=true
  if [[ ${RM_TEST_MODE} == 1 && -n ${RM_UFW_STATUS_FILE:-} ]]; then installed=true; fi
  if [[ $installed == true ]]; then
    text=$(fw_ufw_status_text || true)
    grep -qi '^Status: active' <<<"$text" && active=true
    default_in=$(sed -nE 's/^Default: ([a-z]+) \(incoming\).*/\1/p' <<<"$text" | head -n1); [[ -n $default_in ]] || default_in=unknown
  fi
  if [[ ${RM_TEST_MODE} != 1 ]]; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then complex=true; reason='firewalld 正在运行'; fi
    if rm_have docker && docker info >/dev/null 2>&1; then complex=true; reason="${reason:+$reason; }检测到 Docker 网络"; fi
  fi
  jq -n --argjson installed "$installed" --argjson active "$active" --arg default "$default_in" --argjson complex "$complex" --arg reason "$reason" '{installed:$installed,active:$active,default_incoming:$default,complex_environment:$complex,reason:(if $reason=="" then null else $reason end)}'
}

fw_require_manageable() {
  local s; s=$(fw_status_json)
  jq -e '.installed==true and .active==true and .complex_environment==false' <<<"$s" >/dev/null || {
    rm_error "UFW 未启用或环境存在冲突，自动写规则被禁用: $(jq -c . <<<"$s")"; return "$RM_RC_PRECONDITION";
  }
}

fw_port_external_allow_conflict() {
  local port=$1 text
  text=$(fw_ufw_status_text || true)
  # Conservative: any ALLOW rule for this port not carrying our marker is treated as a conflict.
  awk -v p="$port" 'BEGIN{IGNORECASE=1; bad=0}
    $0 ~ p && $0 ~ /ALLOW/ && $0 !~ /relay-manager:/ {bad=1}
    END{exit bad?0:1}' <<<"$text"
}

fw_rule_args_json() {
  local action=$1 source=$2 port=$3 comment=$4
  if [[ $source == any ]]; then jq -n --arg p "$port" --arg c "$comment" '["allow","to","any","port",$p,"proto","tcp","comment",$c]';
  else jq -n --arg s "$source" --arg p "$port" --arg c "$comment" '["allow","from",$s,"to","any","port",$p,"proto","tcp","comment",$c]'; fi
}

fw_exec_rule_json() {
  local json=$1 op=${2:-add}; mapfile -t args < <(jq -r '.[]' <<<"$json")
  if [[ $op == add ]]; then fw_ufw "${args[@]}"; else fw_ufw --force delete "${args[@]}"; fi
}

fw_apply_whitelist() {
  local nid=$1 port=$2; shift 2; local sources=("$@")
  rm_valid_port "$port" || return "$RM_RC_PRECONDITION"; ((${#sources[@]})) || { rm_error '空白名单默认拒绝全部；请先添加来源或明确继续。'; return "$RM_RC_PRECONDITION"; }
  fw_require_manageable || return $?
  if fw_port_external_allow_conflict "$port"; then rm_error "端口 $port 存在非受管 ALLOW 规则，无法证明白名单隔离，拒绝自动接管。"; return "$RM_RC_PRECONDITION"; fi
  local normalized=() s n; for s in "${sources[@]}"; do n=$(rm_normalize_ip_or_cidr "$s") || return "$RM_RC_PRECONDITION"; normalized+=("$n"); done
  local tx rules='[]' r comment hash applied='[]'
  tx=$(tx_begin firewall-whitelist) || return $?; tx_apply "$tx" || { tx_rollback "$tx" 'firewall transaction start failed' || true; return "$RM_RC_PRECONDITION"; }
  for s in "${normalized[@]}"; do
    hash=$(printf '%s' "$s" | sha256sum | cut -c1-8); comment="relay-manager:$nid:allow:$hash"; r=$(fw_rule_args_json allow "$s" "$port" "$comment")
    if ! fw_exec_rule_json "$r" add; then
      while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$rr" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
      tx_rollback "$tx" 'UFW allow apply failed' || true; return "$RM_RC_APPLY_ROLLED_BACK"
    fi
    applied=$(jq -c --argjson r "$r" '.+[$r]' <<<"$applied")
    rules=$(jq -c --arg nid "$nid" --argjson port "$port" --arg kind allow --arg source "$s" --argjson args "$r" '.+[{node_id:$nid,port:$port,kind:$kind,source:$source,args:$args}]' <<<"$rules")
  done
  # Explicit deny makes a whitelist meaningful even if UFW's default incoming policy is allow.
  comment="relay-manager:$nid:deny"; r=$(jq -n --arg p "$port" --arg c "$comment" '["deny","to","any","port",$p,"proto","tcp","comment",$c]')
  if ! fw_exec_rule_json "$r" add; then
    while IFS= read -r rr; do [[ -n $rr ]] && fw_exec_rule_json "$rr" delete || true; done < <(jq -c '.[]' <<<"$applied" | tac)
    tx_rollback "$tx" 'UFW deny apply failed' || true; return "$RM_RC_APPLY_ROLLED_BACK"
  fi
  rules=$(jq -c --arg nid "$nid" --argjson port "$port" --arg kind deny --arg source any --argjson args "$r" '.+[{node_id:$nid,port:$port,kind:$kind,source:$source,args:$args}]' <<<"$rules")
  tx_commit "$tx"
  state_init >/dev/null
  state_update_filter '.owned_firewall_rules = ([.owned_firewall_rules[]|select(.node_id!=$nid)] + $rules)' --arg nid "$nid" --argjson rules "$rules"
  jq -n --arg nid "$nid" --argjson port "$port" --argjson sources "$(printf '%s\n' "${normalized[@]}" | jq -R -s 'split("\n")|map(select(length>0))')" '{status:"applied_unverified",node_id:$nid,port:$port,sources:$sources,note:"规则已写入，但需线路端真实连接与非白名单对照测试后才能标记白名单有效"}'
}

fw_remove_node_rules() {
  local nid=$1 rules r failed=false
  state_init >/dev/null; rules=$(jq -c --arg nid "$nid" '[.owned_firewall_rules[]|select(.node_id==$nid)]' "$RM_STATE_FILE")
  while IFS= read -r r; do [[ -n $r ]] || continue; if ! fw_exec_rule_json "$(jq -c .args <<<"$r")" delete; then failed=true; fi; done < <(jq -c '.[]' <<<"$rules" | tac)
  [[ $failed == false ]] || { rm_error '部分 UFW 受管规则删除失败，状态未清理'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  state_update_filter '.owned_firewall_rules=[.owned_firewall_rules[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_temp_unit_names() {
  local nid=$1 safe=${nid//[^A-Za-z0-9_.-]/_}; printf 'relay-manager-temp-%s\n' "$safe"
}

fw_temp_open() {
  local nid=$1 minutes=${2:-10}; [[ $minutes =~ ^[0-9]+$ ]] && ((minutes>=1 && minutes<=1440)) || return "$RM_RC_PRECONDITION"
  fw_require_manageable || return $?
  state_init >/dev/null
  local node port now deadline unit comment rule service timer tmpdir tx
  node=$(state_get_node "$nid") || return "$RM_RC_PRECONDITION"; port=$(jq -r .listen_port <<<"$node")
  now=$(rm_epoch); deadline=$((now+minutes*60)); unit=$(fw_temp_unit_names "$nid"); comment="relay-manager:$nid:temporary:$deadline"
  rule=$(jq -n --arg p "$port" --arg c "$comment" '["allow","to","any","port",$p,"proto","tcp","comment",$c]')
  tmpdir=$(rm_safe_tmpdir); service="$tmpdir/$unit.service"; timer="$tmpdir/$unit.timer"
  cat >"$service" <<EOS
[Unit]
Description=Relay Manager temporary public access expiry for $nid
[Service]
Type=oneshot
ExecStart=/usr/local/bin/relay-manager firewall expire-temp $nid
EOS
  cat >"$timer" <<EOS
[Unit]
Description=Relay Manager temporary public access timer for $nid
[Timer]
OnCalendar=@$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOS
  tx=$(tx_begin firewall-temp-open "$deadline") || { rm -rf "$tmpdir"; return $?; }
  tx_stage_file "$tx" "$service" "$(rm_path /etc/systemd/system/$unit.service)" 0644 root:root || { tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_stage_file "$tx" "$timer" "$(rm_path /etc/systemd/system/$unit.timer)" 0644 root:root || { tx_rollback "$tx" 'timer stage failed' || true; rm -rf "$tmpdir"; return "$RM_RC_PRECONDITION"; }
  tx_apply "$tx" || { local rc=$?; tx_rollback "$tx" 'timer apply failed' || true; rm -rf "$tmpdir"; return "$rc"; }
  if ! fw_exec_rule_json "$rule" add; then tx_rollback "$tx" 'temporary UFW rule failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; fi
  if [[ ${RM_TEST_MODE} != 1 ]]; then systemctl daemon-reload && systemctl enable --now "$unit.timer" || { fw_exec_rule_json "$rule" delete || true; tx_rollback "$tx" 'timer enable failed' || true; rm -rf "$tmpdir"; return "$RM_RC_APPLY_ROLLED_BACK"; }; fi
  tx_commit "$tx"
  state_update_filter '.temporary_opens=([.temporary_opens[]|select(.node_id!=$nid)] + [{node_id:$nid,deadline_epoch:$deadline,rule_args:$rule,unit:$unit}])' --arg nid "$nid" --argjson deadline "$deadline" --argjson rule "$rule" --arg unit "$unit"
  rm -rf "$tmpdir"; jq -n --arg nid "$nid" --argjson deadline "$deadline" '{status:"temporary_open_applied_unverified",node_id:$nid,deadline_epoch:$deadline}'
}

fw_expire_temp() {
  local nid=$1 entry unit rule
  state_init >/dev/null; entry=$(jq -c --arg id "$nid" '.temporary_opens[]|select(.node_id==$id)' "$RM_STATE_FILE" 2>/dev/null || true); [[ -n $entry ]] || return 0
  unit=$(jq -r .unit <<<"$entry"); rule=$(jq -c .rule_args <<<"$entry")
  fw_exec_rule_json "$rule" delete || { rm_error '临时开放规则删除失败'; return "$RM_RC_RECOVERY_INCOMPLETE"; }
  if [[ ${RM_TEST_MODE} != 1 ]]; then systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
  rm -f "$(rm_path /etc/systemd/system/$unit.timer)" "$(rm_path /etc/systemd/system/$unit.service)"
  [[ ${RM_TEST_MODE} != 1 ]] && systemctl daemon-reload || true
  state_update_filter '.temporary_opens=[.temporary_opens[]|select(.node_id!=$nid)]' --arg nid "$nid"
}

fw_reconcile_expired() {
  state_init >/dev/null
  local now nid deadline rc=0; now=$(rm_epoch)
  while IFS=$'\t' read -r nid deadline; do [[ -n $nid ]] || continue; if ((deadline<=now)); then fw_expire_temp "$nid" || rc=$?; fi; done < <(jq -r '.temporary_opens[]|[.node_id,.deadline_epoch]|@tsv' "$RM_STATE_FILE")
  return "$rc"
}
