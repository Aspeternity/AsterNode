#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
trap 'rm -rf "$root"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1
source "$PROJECT_DIR/lib/target.sh"

fakebin="$root/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/dig" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"CNAME www.bing.com")
    printf '%s\n' 'www.bing.com. 60 IN CNAME www-www.bing.com.trafficmanager.net.'
    ;;
  *"CNAME www-www.bing.com.trafficmanager.net")
    printf '%s\n' 'www-www.bing.com.trafficmanager.net. 60 IN CNAME www.bing.com.edgekey.net.'
    ;;
  *"CNAME www.bing.com.edgekey.net")
    printf '%s\n' 'www.bing.com.edgekey.net. 60 IN CNAME e86303.dscx.akamaiedge.net.'
    ;;
  *"CNAME e86303.dscx.akamaiedge.net")
    ;;
  *"-x 23.210.216.158")
    printf '%s\n' 'a23-210-216-158.deploy.static.akamaitechnologies.com.'
    ;;
  *)
    ;;
esac
SH
chmod +x "$fakebin/dig"
PATH="$fakebin:$PATH"

risk=$(target_dns_shared_edge_json www.bing.com 23.210.216.158)
assert_json "$risk" '
  .status=="high" and
  (.cname_chain|length)>=3 and
  any(.matches[]; .suffix=="trafficmanager.net") and
  any(.matches[]; .suffix=="edgekey.net") and
  any(.matches[]; .suffix=="akamaiedge.net") and
  any(.matches[]; .suffix=="akamaitechnologies.com")
'

safe=$(target_dns_shared_edge_json origin.example 192.0.2.10)
assert_json "$safe" '
  .status=="low" and
  (.matches|length)==0
'

pass 'Stage B Target DNS CNAME/PTR shared-edge gate blocks Akamai-style chains'
