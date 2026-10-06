#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"
root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT

# The Stage-A source installer is exercised only inside RM_ROOT; it must be idempotent
# and must not create /etc/relay-manager state merely by showing post-install status.
env RM_ROOT="$root" RM_TEST_MODE=1 "$PROJECT_DIR/install.sh" --install-source >/dev/null
version=$(cat "$PROJECT_DIR/VERSION")
base="$root/usr/local/lib/relay-manager"
bin="$root/usr/local/bin/relay-manager"
[[ -x "$bin" ]] || fail 'installed relay-manager entry is not executable'
assert_eq "$base/versions/$version/relay-manager.sh" "$(readlink -f "$bin")"
[[ ! -e "$root/etc/relay-manager/state.json" ]] || fail 'installer status path created managed state'
count1=$(find "$base/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)
sha1=$(sha256sum "$base/versions/$version/relay-manager.sh" | awk '{print $1}')

env RM_ROOT="$root" RM_TEST_MODE=1 "$PROJECT_DIR/install.sh" --install-source >/dev/null
count2=$(find "$base/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)
sha2=$(sha256sum "$base/versions/$version/relay-manager.sh" | awk '{print $1}')
assert_eq "$count1" "$count2" 'reinstall created an extra version directory'
assert_eq "$sha1" "$sha2" 'reinstall rewrote the installed version unexpectedly'
[[ ! -e "$root/etc/relay-manager/state.json" ]] || fail 'reinstall created managed state'

grep -F 'tar fuser dig' "$PROJECT_DIR/install.sh" >/dev/null || fail 'installer does not require fuser/dig'
grep -F 'fuser) pkg=psmisc' "$PROJECT_DIR/install.sh" >/dev/null || fail 'installer does not map fuser to psmisc'
grep -F 'dig) pkg=dnsutils' "$PROJECT_DIR/install.sh" >/dev/null || fail 'installer does not map dig to dnsutils'

if grep -F 'system_pkg_manager_json' "$PROJECT_DIR/install.sh" >/dev/null; then
  fail 'installer dependency bootstrap still requires jq for apt lock inspection'
fi

# Release-package installs must run the same runtime dependency preflight. Hide
# unzip from PATH in test mode so the package path proves it reaches that check
# before attempting archive/signature processing.
fakebin="$work/fakebin"
mkdir "$fakebin"
for c in dirname cat sha256sum; do
  ln -s "$(command -v "$c")" "$fakebin/$c"
done
for c in jq curl openssl ip ss flock tar fuser dig; do
  printf '#!/bin/sh\nexit 0\n' >"$fakebin/$c"
  chmod 0755 "$fakebin/$c"
done
dummy="$work/dummy-package"
printf 'not-a-release-archive\n' >"$dummy"
dummy_sha=$(sha256sum "$dummy" | awk '{print $1}')

rc=0
out=$(env PATH="$fakebin" RM_ROOT="$root" RM_TEST_MODE=1 \
  /bin/bash "$PROJECT_DIR/install.sh" --package "$dummy" --sha256 "$dummy_sha" 2>&1) || rc=$?
assert_eq 10 "$rc" 'package install skipped runtime dependency preflight'
grep -F '隔离测试模式缺少依赖且禁止安装系统包: unzip' <<<"$out" >/dev/null ||
  fail 'package install did not report the missing runtime dependency'

# The pinned outer digest must still be rejected before dependency handling can
# mutate the system.
rc=0
out=$(env PATH="$fakebin" RM_ROOT="$root" RM_TEST_MODE=1 \
  /bin/bash "$PROJECT_DIR/install.sh" --package "$dummy" \
  --sha256 "$(printf '0%.0s' {1..64})" 2>&1) || rc=$?
assert_eq 10 "$rc" 'package install accepted the wrong outer digest'
grep -F '安装包 SHA-256 不匹配' <<<"$out" >/dev/null ||
  fail 'wrong package digest was not rejected before dependency handling'
if grep -F '缺少依赖' <<<"$out" >/dev/null; then
  fail 'dependency handling ran before the outer package digest check'
fi

pass 'Stage-A install entry idempotency, package dependency bootstrap and read-only status'

