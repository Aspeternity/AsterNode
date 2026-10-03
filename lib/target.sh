#!/usr/bin/env bash
# Versioned REALITY target probing; read-only and bounded.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
RM_TARGETS_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/compat/targets.json"

RM_TARGET_HANDSHAKE_ATTEMPTS=2
RM_TARGET_TLS_TIMEOUT_SECONDS=6
RM_TARGET_HTTP_TIMEOUT_SECONDS=5
RM_TARGET_MAX_PARALLEL=2

target_split() {
  rm_split_host_port "$1"
}

target_resolve_host() {
  local host=$1 norm
  if norm=$(rm_normalize_ip_or_cidr "$host" 2>/dev/null) && [[ $norm != */* ]]; then
    printf '%s\n' "$norm"
    return 0
  fi
  getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1;exit}'
}

target_probe() {
  local target=$1 sni=$2 host port resolved start end ms tmpdir first_log second_log hdrfile
  local http_status='unverified' redirect='' redirected=false
  local risk_note='REALITY 未认证流量可能表现为转发到 Target；CDN/共享目标需单独评估滥用与来源限制。本工具不会因 Target 探测自动开放额外端口。'

  rm_split_host_port "$target" >/dev/null 2>&1 || {
    rm_error 'Target 必须为 host:port 或 [IPv6]:port'
    return "$RM_RC_PRECONDITION"
  }
  rm_valid_host "$sni" || {
    rm_error 'SNI 格式无效'
    return "$RM_RC_PRECONDITION"
  }
  if rm_normalize_ip_or_cidr "$sni" >/dev/null 2>&1; then
    rm_error 'SNI 必须使用域名，不能直接使用 IP'
    return "$RM_RC_PRECONDITION"
  fi

  IFS=$'\t' read -r host port < <(target_split "$target")
  resolved=$(target_resolve_host "$host" || true)
  if [[ -z $resolved ]]; then
    jq -n --arg t "$target" --arg s "$sni" --arg risk "$risk_note" \
      --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
      '{status:"failed",target:$t,sni:$s,
        checks:{dns:"failed",tcp:false,tls13:false,certificate_hostname:false,h2:false,repeated_handshake:false,http_redirect:null},
        reason:"DNS/地址解析失败",risk_note:$risk,
        probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
    return 0
  fi

  if ! rm_have openssl || ! rm_have timeout; then
    jq -n --arg t "$target" --arg s "$sni" --arg r "$resolved" --arg risk "$risk_note" \
      --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
      '{status:"unverified",target:$t,sni:$s,resolved_address:$r,
        reason:"缺少 openssl/timeout",risk_note:$risk,
        probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
    return 0
  fi

  tmpdir=$(rm_safe_tmpdir) || return $?
  first_log="$tmpdir/tls-1.log"
  second_log="$tmpdir/tls-2.log"
  hdrfile="$tmpdir/http-headers.txt"

  start=$(date +%s%3N 2>/dev/null || date +%s000)
  set +e
  timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" openssl s_client \
    -connect "$target" -servername "$sni" -verify_hostname "$sni" -verify_return_error \
    -alpn h2 -tls1_3 </dev/null >"$first_log" 2>&1
  local rc1=$?
  set -e
  end=$(date +%s%3N 2>/dev/null || date +%s000)
  ms=$((end-start))

  set +e
  timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" openssl s_client \
    -connect "$target" -servername "$sni" -verify_hostname "$sni" -verify_return_error \
    -alpn h2 -tls1_3 </dev/null >"$second_log" 2>&1
  local rc2=$?
  set -e

  local tcp=false tls=false cert=false h2=false stable=false second_tls=false second_h2=false
  if ((rc1==0)) || grep -aEqi 'CONNECTED|CONNECTION ESTABLISHED|Protocol version:' "$first_log"; then tcp=true; fi
  if ((rc1==0)) && grep -aEqi 'Protocol version:[[:space:]]*TLSv1\.3|Protocol[[:space:]]*:?[[:space:]]*TLSv1\.3|New,[[:space:]]*TLSv1\.3' "$first_log"; then tls=true; fi
  ((rc1==0)) && cert=true
  grep -aEqi 'ALPN protocol:[[:space:]]*h2|Negotiated protocol:[[:space:]]*h2|ALPN.*h2' "$first_log" && h2=true
  grep -aEqi 'Protocol version:[[:space:]]*TLSv1\.3|Protocol[[:space:]]*:?[[:space:]]*TLSv1\.3|New,[[:space:]]*TLSv1\.3' "$second_log" && second_tls=true
  grep -aEqi 'ALPN protocol:[[:space:]]*h2|Negotiated protocol:[[:space:]]*h2|ALPN.*h2' "$second_log" && second_h2=true
  ((rc1==0 && rc2==0)) && [[ $second_tls == true && $second_h2 == true ]] && stable=true

  if rm_have curl; then
    local resolve_arg=$resolved
    [[ $resolved == *:* ]] && resolve_arg="[$resolved]"
    set +e
    curl -sS -o /dev/null -D "$hdrfile" --max-time "$RM_TARGET_HTTP_TIMEOUT_SECONDS" --connect-timeout 2 \
      --resolve "$sni:$port:$resolve_arg" "https://$sni:$port/" >/dev/null 2>&1
    set -e
    if [[ -s $hdrfile ]]; then
      http_status=$(awk 'toupper($1) ~ /^HTTP\// {last=$2; if ($2 !~ /^1[0-9][0-9]$/) final=$2} END{print (final!=""?final:last)}' "$hdrfile")
      [[ -n $http_status ]] || http_status=unverified
      redirect=$(awk 'tolower($1)=="location:" {$1="";sub(/^ /,"");gsub(/\r/,"");loc=$0} END{print loc}' "$hdrfile")
      [[ $http_status =~ ^3[0-9][0-9]$ ]] && redirected=true
    fi
  fi

  local status=unverified reason=''
  if [[ $tcp == true && $tls == true && $cert == true && $h2 == true && $stable == true && $redirected == false ]]; then
    status=suitable_measured
  elif [[ $tcp == false || $tls == false || $cert == false ]]; then
    status=failed
    reason='TCP/TLS 1.3/证书检查未通过'
  elif [[ $redirected == true ]]; then
    reason='Target 域名发生 HTTP 重定向，不满足推荐条件'
  else
    reason='基础握手成功，但 H2 或重复握手稳定性未达到推荐条件'
  fi

  local warning=''
  if [[ $sni == *apple* || $sni == *icloud* ]]; then
    warning='当前固定 Xray 版本会对 Apple/iCloud REALITY Target 给出风险警告，本项目不推荐作为默认候选'
  fi

  jq -n \
    --arg status "$status" --arg t "$target" --arg s "$sni" --arg r "$resolved" \
    --argjson latency "$ms" --argjson tcp "$tcp" --argjson tls "$tls" \
    --argjson cert "$cert" --argjson h2 "$h2" --argjson stable "$stable" \
    --arg http "$http_status" --arg redirect "$redirect" --argjson redirected "$redirected" --arg reason "$reason" \
    --arg warning "$warning" --arg risk "$risk_note" \
    --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" \
    --argjson tls_timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
    --argjson http_timeout "$RM_TARGET_HTTP_TIMEOUT_SECONDS" \
    '{status:$status,target:$t,sni:$s,resolved_address:$r,latency_ms:$latency,
      checks:{dns:"ok",tcp:$tcp,tls13:$tls,certificate_hostname:$cert,h2:$h2,
        repeated_handshake:$stable,http_status:$http,http_redirect:$redirected,
        redirect:(if $redirect=="" then null else $redirect end)},
      reason:(if $reason=="" then null else $reason end),
      warning:(if $warning=="" then null else $warning end),
      note:"HTTP 非 200 不自动等于 REALITY 不可用；HTTP 重定向不进入推荐结果。结果仅代表当前 VPS 本次实测。",
      risk_note:$risk,
      probe_policy:{handshake_attempts:$attempts,tls_timeout_seconds:$tls_timeout,
        http_timeout_seconds:$http_timeout}}'

  rm -rf "$tmpdir"
}

target_probe_candidates() {
  local tmpdir order t s recommendable official_reference risk_class note file results suitable recommended policy idx=0 pid
  local -a pids=()
  tmpdir=$(rm_safe_tmpdir) || return $?

  while IFS=$'\t' read -r order t s recommendable official_reference risk_class note; do
    file=$(printf '%s/%04d.json' "$tmpdir" "$idx")
    (
      target_probe "$t" "$s" |
        jq --argjson order "$order" --argjson recommendable "$recommendable" \
          --argjson official_reference "$official_reference" --arg risk_class "$risk_class" --arg note "$note" \
          '. + {candidate:{order:$order,recommendable:$recommendable,official_reference:$official_reference,risk_class:$risk_class,note:$note}}'
    ) >"$file" &
    pids+=("$!")
    idx=$((idx+1))

    if ((${#pids[@]} >= RM_TARGET_MAX_PARALLEL)); then
      wait "${pids[0]}" || true
      pids=("${pids[@]:1}")
    fi
  done < <(jq -r '.candidates | to_entries[] |
    [.key,.value.target,.value.sni,(if (.value|has("recommendable")) then .value.recommendable else true end),(.value.official_reference//false),(.value.risk_class//"standard"),(.value.note//"")] | @tsv' "$RM_TARGETS_FILE")

  for pid in "${pids[@]}"; do wait "$pid" || true; done

  local f
  for f in "$tmpdir"/*.json; do
    [[ -f $f ]] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then
      jq -n '{status:"unverified",reason:"候选探测子任务未返回有效 JSON"}' >"$f"
    fi
  done

  results=$(jq -s '.' "$tmpdir"/*.json)
  suitable=$(jq '[
      .[] | select(.status=="suitable_measured") |
      {target,sni,resolved_address,latency_ms,candidate}
    ] | sort_by(.latency_ms)' <<<"$results")
  recommended=$(jq '[
      .[] |
      select(.status=="suitable_measured" and (if (.candidate|has("recommendable")) then .candidate.recommendable else true end)==true) |
      . + {_selection_rank:[.latency_ms,(if (.candidate.official_reference//false) then 0 else 1 end),(.candidate.order//999)]}
    ] | sort_by(._selection_rank) |
      (.[0] // null) |
      if .==null then null else
        {target,sni,resolved_address,latency_ms,candidate,
         selection_reason:"recommendable suitable_measured 中实测握手延迟最低；同延迟时优先官方参考候选"}
      end' <<<"$results")
  policy=$(jq -r .policy "$RM_TARGETS_FILE")

  jq -n --argjson results "$results" --argjson suitable "$suitable" --argjson recommended "$recommended" --arg policy "$policy" \
    --argjson max_parallel "$RM_TARGET_MAX_PARALLEL" \
    --argjson attempts "$RM_TARGET_HANDSHAKE_ATTEMPTS" \
    --argjson timeout "$RM_TARGET_TLS_TIMEOUT_SECONDS" \
    '{results:$results,
      suitable:$suitable,
      recommended:$recommended,
      policy:$policy,
      auto_selected:false,
      auto_applied:false,
      selection_basis:"只在 recommendable=true、无 HTTP 重定向且 suitable_measured 的候选中按当前 VPS 实测握手延迟选择；不会自动写入节点配置",
      probe_policy:{max_parallel:$max_parallel,handshake_attempts:$attempts,tls_timeout_seconds:$timeout}}'
  rm -rf "$tmpdir"
}
