#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/target.sh"

fakebin="$root/fakebin"
mkdir -p "$fakebin"

cat >"$fakebin/getent" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} != ahosts ]]; then exit 2; fi
case "${2:-}" in
  mixed.example)
    printf '%s\n' \
      '2001:db8::10 STREAM mixed.example' \
      '2001:db8::10 DGRAM mixed.example' \
      '192.0.2.20 STREAM mixed.example'
    ;;
  safe.example)
    printf '%s\n' \
      '2001:db8::20 STREAM safe.example' \
      '192.0.2.21 STREAM safe.example'
    ;;
  unverified.example)
    printf '%s\n' \
      '2001:db8::30 STREAM unverified.example' \
      '192.0.2.30 STREAM unverified.example'
    ;;
  cross.example)
    printf '%s\n' \
      '2001:db8::40 STREAM cross.example' \
      '192.0.2.40 STREAM cross.example'
    ;;
  single.example)
    printf '%s\n' '192.0.2.50 STREAM single.example'
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$fakebin/getent"

cat >"$fakebin/dig" <<'SH'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *" +short -x 192.0.2.20 "*)
    printf '%s\n' 'edge.cloudfront.net.'
    ;;
  *" +short -x 192.0.2.30 "*)
    exit 1
    ;;
  *)
    # No CNAME/PTR answer is a successful low-risk lookup in this fixture.
    ;;
esac
SH
chmod +x "$fakebin/dig"

cat >"$fakebin/openssl" <<'SH'
#!/usr/bin/env bash
connect=''
servername=''
while (($#)); do
  case "$1" in
    -connect)
      shift
      connect=${1:-}
      ;;
    -servername)
      shift
      servername=${1:-}
      ;;
  esac
  shift || true
done

case "$servername" in
  mixed.example|safe.example|unverified.example|cross.example|single.example)
    printf '%s\n' \
      'CONNECTED(00000003)' \
      'Protocol version: TLSv1.3' \
      'ALPN protocol: h2'
    exit 0
    ;;
esac

# Only the second address of cross.example accepts an unrelated SNI.
if [[ "$connect" == 192.0.2.40:443 && "$servername" == www.cloudflare.com ]]; then
  printf '%s\n' \
    'CONNECTED(00000003)' \
    'Protocol version: TLSv1.3' \
    'ALPN protocol: h2'
  exit 0
fi

exit 1
SH
chmod +x "$fakebin/openssl"

cat >"$fakebin/curl" <<'SH'
#!/usr/bin/env bash
headers=''
while (($#)); do
  case "$1" in
    -D)
      shift
      headers=${1:-}
      ;;
  esac
  shift || true
done
[[ -n "$headers" ]] || exit 2
printf 'HTTP/2 200\r\n\r\n' >"$headers"
SH
chmod +x "$fakebin/curl"

PATH="$fakebin:$PATH"

mock_targets="$root/targets.json"
jq -n '{
  candidates:[
    {target:"mixed.example:443",sni:"mixed.example",recommendable:true,official_reference:false,risk_class:"standard"},
    {target:"safe.example:443",sni:"safe.example",recommendable:true,official_reference:false,risk_class:"standard"}
  ],
  policy:"Bug20 multi-address unit fixture",
  shared_edge_suffixes:["cloudfront.net"]
}' >"$mock_targets"
RM_TARGETS_FILE="$mock_targets"

mixed=$(target_probe mixed.example:443 mixed.example)
assert_json "$mixed" '
  .status=="suitable_measured" and
  .resolved_address=="2001:db8::10" and
  .resolved_addresses==["2001:db8::10","192.0.2.20"] and
  .recommendation_eligible==false and
  .abuse_risk.status=="high" and
  any(.address_risks[];
    .address=="192.0.2.20" and
    .status=="high" and
    any(.shared_edge.matches[]; .suffix=="cloudfront.net"))
'

safe=$(target_probe safe.example:443 safe.example)
assert_json "$safe" '
  .status=="suitable_measured" and
  .resolved_addresses==["2001:db8::20","192.0.2.21"] and
  .recommendation_eligible==true and
  .abuse_risk.status=="low" and
  (.address_risks|length)==2 and
  all(.address_risks[]; .status=="low")
'

unverified=$(target_probe unverified.example:443 unverified.example)
assert_json "$unverified" '
  .status=="suitable_measured" and
  .recommendation_eligible==false and
  .abuse_risk.status=="unverified" and
  any(.address_risks[]; .address=="192.0.2.30" and .status=="unverified")
'

cross=$(target_probe cross.example:443 cross.example)
assert_json "$cross" '
  .status=="suitable_measured" and
  .recommendation_eligible==false and
  .abuse_risk.status=="high" and
  any(.address_risks[];
    .address=="192.0.2.40" and
    .cross_sni.status=="high" and
    .status=="high")
'

single=$(target_probe single.example:443 single.example)
assert_json "$single" '
  .status=="suitable_measured" and
  .resolved_address=="192.0.2.50" and
  .resolved_addresses==["192.0.2.50"] and
  .recommendation_eligible==true and
  .abuse_risk.status=="low" and
  (.address_risks|length)==1
'

# Candidate selection must prefer an all-low target over a faster target that
# contains any high-risk resolved address.
target_probe() {
  local target=$1 sni=$2
  case "$target" in
    mixed.example:443)
      jq -n --arg t "$target" --arg s "$sni" '{
        status:"suitable_measured",target:$t,sni:$s,resolved_address:"2001:db8::10",
        resolved_addresses:["2001:db8::10","192.0.2.20"],latency_ms:5,
        abuse_risk:{status:"high"},recommendation_eligible:false
      }'
      ;;
    safe.example:443)
      jq -n --arg t "$target" --arg s "$sni" '{
        status:"suitable_measured",target:$t,sni:$s,resolved_address:"2001:db8::20",
        resolved_addresses:["2001:db8::20","192.0.2.21"],latency_ms:20,
        abuse_risk:{status:"low"},recommendation_eligible:true
      }'
      ;;
    *)
      return 1
      ;;
  esac
}

candidates=$(target_probe_candidates)
assert_json "$candidates" '
  .recommended.target=="safe.example:443" and
  .recommended.abuse_risk.status=="low" and
  (.results|length)==2 and
  any(.results[]; .target=="mixed.example:443" and .recommendation_eligible==false)
'

pass 'Bug20 multi-address Target safety is fail-closed across every resolved address'
