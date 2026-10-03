#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/target.sh"

assert_json "$(cat "$RM_TARGETS_FILE")" '
  .schema_version==2 and
  (.candidates|length)>=10 and
  all(.candidates[]; (.target|type)=="string" and (.sni|type)=="string" and (.recommendable|type)=="boolean") and
  (any(.candidates[]; .sni=="www.microsoft.com")) and
  (any(.candidates[]; .sni=="dl.google.com" and .official_reference==true and .recommendable==true)) and
  (any(.candidates[]; .sni=="www.cloudflare.com" and .recommendable==false and .risk_class=="shared-cdn-forwarding")) and
  (all(.candidates[]; (.sni|ascii_downcase|contains("apple")|not)))
'

set +e
target_probe 'bad-target' 'www.example.com' >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'malformed Target was accepted'

set +e
target_probe '127.0.0.1:443' '127.0.0.1' >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'IP literal was accepted as REALITY SNI'

probe=$(target_probe '127.0.0.1:1' 'www.example.com')
assert_json "$probe" '
  .status=="failed" and
  .target=="127.0.0.1:1" and
  .checks.tcp==false and
  .checks.tls13==false and
  .checks.certificate_hostname==false and
  .probe_policy.handshake_attempts==2 and
  .probe_policy.tls_timeout_seconds==6 and
  (.risk_note|contains("不会因 Target 探测自动开放额外端口"))
'

# Regression: OpenSSL full output exposes ALPN h2 while -brief may omit it.
# Include a NUL byte to ensure probe output is parsed from files rather than command substitution.
fakebin="$root/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/openssl" <<'SH'
#!/usr/bin/env bash
printf 'CONNECTED(00000003)\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nVerification: OK\nALPN protocol: h2\nVerify return code: 0 (ok)\n'
printf '\0binary-tail\n'
SH
chmod +x "$fakebin/openssl"

PATH_ORIG=$PATH
PATH="$fakebin:$PATH"
rm_have() {
  [[ $1 == curl ]] && return 1
  command -v "$1" >/dev/null 2>&1
}
nul_stderr="$root/nul-stderr.txt"
probe=$(target_probe '127.0.0.1:443' 'www.example.com' 2>"$nul_stderr")
assert_json "$probe" '
  .status=="suitable_measured" and
  .checks.tcp==true and
  .checks.tls13==true and
  .checks.certificate_hostname==true and
  .checks.h2==true and
  .checks.repeated_handshake==true and
  .checks.http_redirect==false
'
grep -F 'ignored null byte' "$nul_stderr" >/dev/null && fail 'Target probe still feeds NUL bytes through command substitution'
PATH=$PATH_ORIG
rm_have() { command -v "$1" >/dev/null 2>&1; }

mock_targets="$root/targets.json"
jq -n '{
  candidates:[
    {target:"safe-slow.example:443",sni:"safe-slow.example",recommendable:true,official_reference:true,risk_class:"standard"},
    {target:"safe-fast.example:443",sni:"safe-fast.example",recommendable:true,official_reference:false,risk_class:"standard"},
    {target:"cdn-fast.example:443",sni:"cdn-fast.example",recommendable:false,official_reference:false,risk_class:"shared-cdn-forwarding"}
  ],
  policy:"unit-test recommendation candidates"
}' >"$mock_targets"
RM_TARGETS_FILE="$mock_targets"
target_probe() {
  local target=$1 sni=$2 latency
  case "$target" in
    safe-slow.example:443) latency=40 ;;
    safe-fast.example:443) latency=20 ;;
    cdn-fast.example:443) latency=5 ;;
    *) latency=99 ;;
  esac
  jq -n --arg t "$target" --arg s "$sni" --argjson latency "$latency" '{
    status:"suitable_measured",target:$t,sni:$s,resolved_address:"192.0.2.1",latency_ms:$latency,
    checks:{dns:"ok",tcp:true,tls13:true,certificate_hostname:true,h2:true,repeated_handshake:true,http_status:"200",http_redirect:false,redirect:null},
    reason:null
  }'
}
candidates=$(target_probe_candidates)
assert_json "$candidates" '
  (.results|length)==3 and
  (.suitable|length)==3 and
  .recommended.target=="safe-fast.example:443" and
  .recommended.latency_ms==20 and
  .recommended.candidate.recommendable==true and
  .auto_selected==false and
  .auto_applied==false and
  (.selection_basis|contains("不会自动写入节点配置")) and
  .probe_policy.max_parallel==2 and
  .probe_policy.handshake_attempts==2
'

pass 'Stage B Target candidate data, bounded retries and controlled parallel probing'
