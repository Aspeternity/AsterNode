#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1

priv="$work/release.key"
pub="$work/release.pub.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$priv" >/dev/null 2>&1
openssl pkey -in "$priv" -pubout -out "$pub" >/dev/null 2>&1

version=$(cat "$PROJECT_DIR/VERSION")
commit=1111111111111111111111111111111111111111
mkdir -p "$work/out"
SOURCE_DATE_EPOCH=1700000000 "$PROJECT_DIR/tools/release/build-package.sh"   --version "$version" --commit "$commit" --signing-key "$priv" --out "$work/out" >"$work/build.json"

package=$(jq -r .package "$work/build.json")
sha=$(jq -r .sha256 "$work/build.json")
built_pub=$(jq -r .public_key "$work/build.json")
[[ -f $package && -f $package.sha256 && -f $built_pub ]] || fail 'release builder did not emit expected artifacts'
assert_eq "$sha" "$(sha256sum "$package" | awk '{print $1}')" 'outer package digest mismatch'

source "$PROJECT_DIR/lib/update.sh"
top=$(update_safe_tar_list "$package")
assert_eq "relay-manager-$version" "$top" 'unexpected release package root'

tmp="$work/verify"
mkdir "$tmp"
tar -xzf "$package" -C "$tmp"
update_verify_release_dir "$tmp/$top" "$built_pub"

installed=$(update_install_manager_package "$package" "$sha" "$built_pub")
assert_json "$installed" '.status=="installed" and .version=="'"$version"'"'
assert_eq "$root/usr/local/lib/relay-manager/versions/$version/relay-manager.sh" "$(readlink -f "$root/usr/local/bin/relay-manager")"
assert_file_mode "$root/etc/relay-manager/trusted-release.pem" 644
assert_file_mode "$root/usr/local/lib/relay-manager/versions/$version/MANIFEST.json" 644

# Same verified release is idempotent and does not create a duplicate version.
update_install_manager_package "$package" "$sha" "$built_pub" >/dev/null
assert_eq 1 "$(find "$root/usr/local/lib/relay-manager/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)" 'idempotent install created another version'

# Outer digest mismatch must fail before extraction/install.
rc=0
update_install_manager_package "$package" "$(printf '0%.0s' {1..64})" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'wrong outer digest was accepted'

# A package signed by another key must not be accepted with the trusted key.
priv2="$work/release2.key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$priv2" >/dev/null 2>&1
mkdir "$work/out2"
SOURCE_DATE_EPOCH=1700000000 "$PROJECT_DIR/tools/release/build-package.sh"   --version "$version" --commit 2222222222222222222222222222222222222222 --signing-key "$priv2" --out "$work/out2" >"$work/build2.json"
package2=$(jq -r .package "$work/build2.json")
sha2=$(jq -r .sha256 "$work/build2.json")
rc=0
update_install_manager_package "$package2" "$sha2" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'package with wrong signing key was accepted'

# Extra unsigned payload must be rejected even when the original checksum signature remains valid.
extra="$work/extra"
mkdir "$extra"
tar -xzf "$package" -C "$extra"
printf 'unexpected\n' >"$extra/$top/UNDECLARED"
extra_pkg="$work/extra.tar.gz"
tar -C "$extra" -czf "$extra_pkg" "$top"
extra_sha=$(sha256sum "$extra_pkg" | awk '{print $1}')
rc=0
update_install_manager_package "$extra_pkg" "$extra_sha" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'undeclared extra payload was accepted'

# Traversal-style archive names are rejected before extraction.
mkdir "$work/mal"
printf x >"$work/mal/file"
mal="$work/malicious.tar.gz"
tar -C "$work/mal" --transform='s|^|../relay-manager-bad/|' -czf "$mal" file 2>/dev/null || true
if [[ -s $mal ]]; then
  rc=0
  update_safe_tar_list "$mal" >/dev/null 2>&1 || rc=$?
  assert_eq 10 "$rc" 'path traversal archive was accepted'
fi

pass 'Stage D signed package build, manifest/signature verification, trust pinning and idempotent install'
