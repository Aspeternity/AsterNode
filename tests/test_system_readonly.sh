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

# A minimal Debian image may not have fuser yet. The package-manager probe must
# still be able to prove a clear/occupied lock state from RM_ROOT /proc fixtures.
pkg_clear=$(
  rm_have() {
    [[ $1 == fuser ]] && return 1
    command -v "$1" >/dev/null 2>&1
  }
  system_pkg_manager_json
)
assert_json "$pkg_clear" '.kind=="apt" and .locked==false and .lock_status=="clear" and (.reason|contains("/proc"))'

mkdir -p "$root/var/lib/dpkg" "$root/proc/4242/fd"
: >"$root/var/lib/dpkg/lock-frontend"
ln -s "$root/var/lib/dpkg/lock-frontend" "$root/proc/4242/fd/3"
pkg_locked=$(
  rm_have() {
    [[ $1 == fuser ]] && return 1
    command -v "$1" >/dev/null 2>&1
  }
  system_pkg_manager_json
)
assert_json "$pkg_locked" '.locked==true and .lock_status=="locked" and (.reason|contains("/var/lib/dpkg/lock-frontend"))'

# AsterNode-managed Xray is not installed in PATH. Status must still report it
# as the primary Xray component while keeping external discovery separate.
managed_dir="$root/usr/local/lib/relay-manager/core/v26.3.27"
mkdir -p "$managed_dir"
printf '#!/usr/bin/env bash\nexit 0\n' >"$managed_dir/xray"
chmod 0755 "$managed_dir/xray"
ln -s "$managed_dir" "$root/usr/local/lib/relay-manager/core/current"
managed_out=$(system_probe_fast root 198.51.100.10)
assert_json "$managed_out" '
  .components.xray.installed==true and
  .components.xray.managed==true and
  .components.xray.source=="asternode-managed" and
  .components.xray.version=="v26.3.27" and
  .components.xray_managed.installed==true and
  .components.xray_external.installed==false and
  .components.xray_external.managed==false
'

pass 'ENV-01/ENV-02 read-only fixture probe'
