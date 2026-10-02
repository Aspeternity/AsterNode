#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/etc" "$root/proc" "$root/run/systemd/system" "$root/usr/bin" "$root/usr/lib/systemd"
cat > "$root/etc/os-release" <<'OS'
ID=debian
VERSION_ID="12"
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
OS
cat > "$root/proc/meminfo" <<'MEM'
MemTotal:        262144 kB
MemAvailable:    131072 kB
MEM
: > "$root/usr/bin/apt-get"; chmod +x "$root/usr/bin/apt-get"
: > "$root/usr/lib/systemd/systemd"; chmod +x "$root/usr/lib/systemd/systemd"

export RM_ROOT="$root" RM_TEST_MODE=1 RM_TEST_USE_HOST_PROBES=0
source "$PROJECT_DIR/lib/system.sh"
before=$(snapshot_tree "$root")
out=$(system_probe_fast root 198.51.100.10)
after=$(snapshot_tree "$root")
assert_eq "$before" "$after" 'system_probe_fast modified fixture tree'
assert_json "$out" '.probe_mode=="read-only"'
assert_json "$out" '.support.os.id=="debian" and .support.os.version=="12" and .support.os_supported==true'
assert_json "$out" '.support.arch.supported==true'
assert_json "$out" '.support.systemd==true'
assert_json "$out" '.memory.total_bytes==268435456 and .memory.available_bytes==134217728'
assert_json "$out" '.package_manager.kind=="apt"'
assert_json "$out" '.network.address_status=="unverified" and .network.listener_status=="unverified"'
assert_json "$out" '.ssh.context.user=="root" and .ssh.login_verified==false'

pass 'ENV-01/ENV-02 read-only fixture probe'
