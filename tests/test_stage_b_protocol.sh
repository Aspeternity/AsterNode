#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/stage_b_testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
stage_b_fake_core "$root"

spec="$root/spec.json"
stage_b_base_spec "$spec" "2001:db8::10"
vr="$PROJECT_DIR/protocols/vless-reality.sh"

"$vr" validate "$spec"
server=$("$vr" render_server "$spec")
client=$("$vr" render_client "$spec" up-line-a)
uri=$("$vr" render_uri "$spec" up-line-a)

assert_json "$server" '
  (.inbounds|length)==1 and
  .inbounds[0].protocol=="vless" and
  .inbounds[0].streamSettings.network=="raw" and
  .inbounds[0].streamSettings.security=="reality" and
  .inbounds[0].streamSettings.realitySettings.target=="www.microsoft.com:443" and
  .inbounds[0].streamSettings.realitySettings.limitFallbackUpload.bytesPerSec==524288 and
  .inbounds[0].streamSettings.realitySettings.limitFallbackDownload.bytesPerSec==786432 and
  (.inbounds[0].settings.clients|length)==2
'
assert_json "$client" '
  .protocol=="vless" and
  .settings.vnext[0].users[0].encryption=="none" and
  .settings.vnext[0].users[0].flow=="xtls-rprx-vision" and
  .streamSettings.network=="raw" and
  .streamSettings.realitySettings.password=="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" and
  (.streamSettings.realitySettings|has("publicKey")|not)
'
[[ $uri == vless://aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa@\[2001:db8::10\]:443* ]] ||
  fail "IPv6 URI endpoint was not bracketed: $uri"
[[ $uri == *"type=tcp"* && $uri == *"headerType=none"* && $uri == *"spx=%2F"* ]] ||
  fail "share URI compatibility fields missing: $uri"
[[ $uri != *"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"* ]] ||
  fail 'server private key leaked into URI'

disabled="$root/disabled.json"
jq '.upstreams[0].enabled=false' "$spec" >"$disabled"
"$vr" validate "$disabled"
disabled_server=$("$vr" render_server "$disabled")
assert_json "$disabled_server" '
  (.inbounds[0].settings.clients|length)==1 and
  .inbounds[0].settings.clients[0].id=="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
'

bad_bool="$root/bad-bool.json"
jq '.node.enabled="false"' "$spec" >"$bad_bool"
set +e
"$vr" validate "$bad_bool" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'string false was accepted as node.enabled'

dup="$root/dup.json"
jq '.upstreams[1].uuid=.upstreams[0].uuid' "$spec" >"$dup"
set +e
"$vr" validate "$dup" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'duplicate UUID was accepted'

loop="$root/loop.json"
jq '.node.target="[2001:db8::10]:443"' "$spec" >"$loop"
set +e
"$vr" validate "$loop" >/dev/null 2>&1
rc=$?
set -e
assert_eq 10 "$rc" 'REALITY self-loop target was accepted'

sid=$("$vr" generate_short_id)
[[ $sid =~ ^[0-9a-f]{16}$ ]] || fail "Short ID is not 8 random bytes in hex: $sid"
kp=$("$vr" generate_keypair "$root/usr/local/lib/relay-manager/core/current/xray")
assert_json "$kp" '.private_key|length==43'
assert_json "$kp" '.password|length==43'
limits=$("$vr" generate_fallback_limits)
assert_json "$limits" '
  .upload.after_bytes>=2097152 and .upload.after_bytes<=6291456 and
  .upload.bytes_per_sec>=262144 and .upload.bytes_per_sec<=786432 and
  .upload.burst_bytes_per_sec>=1048576 and
  .download.after_bytes>=2097152 and .download.after_bytes<=6291456 and
  .download.bytes_per_sec>=393216 and .download.bytes_per_sec<=1048576 and
  .download.burst_bytes_per_sec>=1572864
'

pass 'Stage B VLESS RAW/TCP REALITY rendering, validation, URI, credentials and randomized fallback limits'
