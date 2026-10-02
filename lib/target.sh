#!/usr/bin/env bash
# Versioned REALITY target probing; read-only and bounded.
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
RM_TARGETS_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/compat/targets.json"

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
  local target=$1 sni=$2 host port resolved start end ms r1 r2 http_status='unverified' redirect=''
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
    jq -n \
      --arg t "$target" \
      --arg s "$sni" \
      --arg risk "$risk_note" \
      '{
        status:"failed",
        target:$t,
        sni:$s,
        checks:{
          dns:"failed",
          tcp:"unverified",
          tls13:false,
          certificate_hostname:false,
          h2:false,
          repeated_handshake:false
        },
        reason:"DNS/地址解析失败",
        risk_note:$risk
      }'
    return 0
  fi

  if ! rm_have openssl || ! rm_have timeout; then
    jq -n \
      --arg t "$target" \
      --arg s "$sni" \
      --arg r "$resolved" \
      --arg risk "$risk_note" \
      '{
        status:"unverified",
        target:$t,
        sni:$s,
        resolved_address:$r,
        reason:"缺少 openssl/timeout",
        risk_note:$risk
      }'
    return 0
  fi

  start=$(date +%s%3N 2>/dev/null || date +%s000)
  set +e
  r1=$(timeout 6 openssl s_client \
    -connect "$target" \
    -servername "$sni" \
    -verify_hostname "$sni" \
    -verify_return_error \
    -alpn h2 \
    -tls1_3 \
    -brief </dev/null 2>&1)
  local rc1=$?
  set -e
  end=$(date +%s%3N 2>/dev/null || date +%s000)
  ms=$((end-start))

  set +e
  r2=$(timeout 6 openssl s_client \
    -connect "$target" \
    -servername "$sni" \
    -verify_hostname "$sni" \
    -verify_return_error \
    -alpn h2 \
    -tls1_3 \
    -brief </dev/null 2>&1)
  local rc2=$?
  set -e

  local tcp=false tls=false cert=false h2=false stable=false
  if ! grep -Eqi 'connect:errno=|Connection refused|No route to host|Network is unreachable|Connection timed out' <<<"$r1"; then
    tcp=true
  fi
  ((rc1==0)) && grep -Eq 'Protocol version: TLSv1\.3|Protocol.*TLSv1\.3' <<<"$r1" && tls=true
  ((rc1==0)) && cert=true
  grep -Eqi 'ALPN.*h2|Negotiated protocol: h2' <<<"$r1" && h2=true
  ((rc1==0 && rc2==0)) && stable=true

  if rm_have curl; then
    local resolve_arg=$resolved hdr
    [[ $resolved == *:* ]] && resolve_arg="[$resolved]"
    hdr=$(curl -IsS \
      --max-time 5 \
      --connect-timeout 2 \
      --resolve "$sni:$port:$resolve_arg" \
      "https://$sni:$port/" 2>/dev/null | head -n8 || true)
    http_status=$(awk 'toupper($1) ~ /^HTTP\// {print $2; exit}' <<<"$hdr")
    [[ -n $http_status ]] || http_status=unverified
    redirect=$(awk 'tolower($1)=="location:" {$1="";sub(/^ /,"");gsub(/\r/,"");print;exit}' <<<"$hdr")
  fi

  local status=unverified reason=''
  if [[ $tcp == true && $tls == true && $cert == true && $h2 == true && $stable == true ]]; then
    status=suitable_measured
  elif [[ $tcp == false || $tls == false || $cert == false ]]; then
    status=failed
    reason='TCP/TLS 1.3/证书检查未通过'
  else
    reason='基础握手成功，但 H2 或重复握手稳定性未达到推荐条件'
  fi

  local warning=''
  if [[ $sni == *apple* || $sni == *icloud* ]]; then
    warning='当前固定 Xray 版本会对 Apple/iCloud REALITY Target 给出风险警告，本项目不推荐作为默认候选'
  fi

  jq -n \
    --arg status "$status" \
    --arg t "$target" \
    --arg s "$sni" \
    --arg r "$resolved" \
    --argjson latency "$ms" \
    --argjson tcp "$tcp" \
    --argjson tls "$tls" \
    --argjson cert "$cert" \
    --argjson h2 "$h2" \
    --argjson stable "$stable" \
    --arg http "$http_status" \
    --arg redirect "$redirect" \
    --arg reason "$reason" \
    --arg warning "$warning" \
    --arg risk "$risk_note" \
    '{
      status:$status,
      target:$t,
      sni:$s,
      resolved_address:$r,
      latency_ms:$latency,
      checks:{
        dns:"ok",
        tcp:$tcp,
        tls13:$tls,
        certificate_hostname:$cert,
        h2:$h2,
        repeated_handshake:$stable,
        http_status:$http,
        redirect:(if $redirect=="" then null else $redirect end)
      },
      reason:(if $reason=="" then null else $reason end),
      warning:(if $warning=="" then null else $warning end),
      note:"HTTP 非 200 不自动等于 REALITY 不可用；结果仅代表目标 VPS 本次实测，最终由用户确认。",
      risk_note:$risk
    }'
}

target_probe_candidates() {
  local results='[]' t s r
  while IFS=$'\t' read -r t s; do
    r=$(target_probe "$t" "$s")
    results=$(jq -c --argjson r "$r" '.+[$r]' <<<"$results")
  done < <(jq -r '.candidates[]|[.target,.sni]|@tsv' "$RM_TARGETS_FILE")

  jq -n \
    --argjson results "$results" \
    --arg policy "$(jq -r .policy "$RM_TARGETS_FILE")" \
    '{
      results:$results,
      suitable:[
        $results[]
        | select(.status=="suitable_measured")
        | {target,sni,latency_ms}
      ],
      policy:$policy,
      auto_selected:false
    }'
}
