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
commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 'could not resolve release commit'
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
update_verify_release_dir "$root/usr/local/lib/relay-manager/versions/$version" "$built_pub"

smoke_stdout=$(update_run_release_smoke "$root/usr/local/lib/relay-manager/versions/$version")
assert_eq '' "$smoke_stdout" 'release smoke polluted machine-readable stdout'

# Managed-link inspection must distinguish a genuinely absent first-install path from readlink -f canonicalization.
rm -f "$root/usr/local/bin/relay-manager" "$root/usr/local/lib/relay-manager/current"
assert_eq '' "$(update_current_managed_version_path)" 'absent current path was misdetected as an unmanaged installation'
update_validate_bin_link ''
ln -s "$root/usr/local/lib/relay-manager/versions/$version" "$root/usr/local/lib/relay-manager/current"
ln -s "$root/usr/local/lib/relay-manager/current/relay-manager.sh" "$root/usr/local/bin/relay-manager"
assert_eq "$root/usr/local/lib/relay-manager/versions/$version" "$(update_current_managed_version_path)" 'managed current link was not resolved'
update_validate_bin_link "$root/usr/local/lib/relay-manager/versions/$version"

# A foreign current symlink must never be treated as managed.
mkdir -p "$work/foreign-manager"
rm -f "$root/usr/local/lib/relay-manager/current"
ln -s "$work/foreign-manager" "$root/usr/local/lib/relay-manager/current"
rc=0
update_install_manager_package "$package" "$sha" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'foreign current link was accepted as managed'
rm -f "$root/usr/local/lib/relay-manager/current"
ln -s "$root/usr/local/lib/relay-manager/versions/$version" "$root/usr/local/lib/relay-manager/current"

# A foreign command path must never be overwritten.
rm -f "$root/usr/local/bin/relay-manager"
printf '#!/bin/sh\n' >"$root/usr/local/bin/relay-manager"
chmod 0755 "$root/usr/local/bin/relay-manager"
rc=0
update_install_manager_package "$package" "$sha" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'foreign relay-manager command path was overwritten'
rm -f "$root/usr/local/bin/relay-manager"
ln -s "$root/usr/local/lib/relay-manager/current/relay-manager.sh" "$root/usr/local/bin/relay-manager"

# Same verified release is idempotent and must not destroy a real rollback pointer.
sentinel="$root/usr/local/lib/relay-manager/versions/previous-sentinel"
state_update_filter '.previous_manager_path=$p' --arg p "$sentinel"
again=$(update_install_manager_package "$package" "$sha" "$built_pub")
assert_json "$again" '.status=="already_installed" and .previous_path_preserved==true'
assert_eq "$sentinel" "$(jq -r '.previous_manager_path' "$RM_STATE_FILE")" 'idempotent install rewrote the rollback pointer'
assert_eq 1 "$(find "$root/usr/local/lib/relay-manager/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)" 'idempotent install created another version'

# Outer digest mismatch must fail before extraction/install.
rc=0
update_install_manager_package "$package" "$(printf '0%.0s' {1..64})" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'wrong outer digest was accepted'

# A package signed by another key must not be accepted with the trusted key.
priv2="$work/release2.key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$priv2" >/dev/null 2>&1
mkdir "$work/out2"
SOURCE_DATE_EPOCH=1700000000 "$PROJECT_DIR/tools/release/build-package.sh"   --version "$version" --commit "$commit" --signing-key "$priv2" --out "$work/out2" >"$work/build2.json"
package2=$(jq -r .package "$work/build2.json")
sha2=$(jq -r .sha256 "$work/build2.json")
rc=0
update_install_manager_package "$package2" "$sha2" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'package with wrong signing key was accepted'

# A valid signature with appended trailing bytes must be rejected. OpenSSL may
# otherwise accept the valid signature prefix and ignore the extra bytes.
sigtrail="$work/signature-trailing"
mkdir "$sigtrail"
tar -xzf "$package" -C "$sigtrail"
printf x >>"$sigtrail/$top/RELEASE.sig"
sigtrail_pkg="$work/signature-trailing.tar.gz"
tar -C "$sigtrail" -czf "$sigtrail_pkg" "$top"
sigtrail_sha=$(sha256sum "$sigtrail_pkg" | awk '{print $1}')
rc=0
update_install_manager_package "$sigtrail_pkg" "$sigtrail_sha" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'release signature with trailing data was accepted'
assert_eq "$root/usr/local/lib/relay-manager/versions/$version" "$(readlink -f "$root/usr/local/lib/relay-manager/current")" 'signature trailing-data rejection changed current manager'

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

# A valid signed payload under the wrong top-level directory must be rejected.
wrongroot="$work/wrongroot"
mkdir "$wrongroot"
tar -xzf "$package" -C "$wrongroot"
mv "$wrongroot/$top" "$wrongroot/relay-manager-wrong"
wrongroot_pkg="$work/wrongroot.tar.gz"
tar -C "$wrongroot" -czf "$wrongroot_pkg" relay-manager-wrong
wrongroot_sha=$(sha256sum "$wrongroot_pkg" | awk '{print $1}')
rc=0
update_install_manager_package "$wrongroot_pkg" "$wrongroot_sha" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'archive root name was not bound to the signed manifest version'

# Trust-anchor installer failures must propagate with their original exit code.
(
  update_install_trusted_key() { return "$RM_RC_NETWORK"; }
  rc=0
  update_install_manager_package "$package" "$sha" "$built_pub" >/dev/null 2>&1 || rc=$?
  assert_eq "$RM_RC_NETWORK" "$rc" 'trust-anchor failure exit code was lost'
)

# Atomic link-switch failures must also propagate and keep an existing verified version.
rm -f "$root/usr/local/bin/relay-manager" "$root/usr/local/lib/relay-manager/current"
(
  update_switch_manager_links() { return "$RM_RC_INTERNAL"; }
  rc=0
  update_install_manager_package "$package" "$sha" "$built_pub" >/dev/null 2>&1 || rc=$?
  assert_eq "$RM_RC_INTERNAL" "$rc" 'manager-link switch failure exit code was lost'
)
[[ -d "$root/usr/local/lib/relay-manager/versions/$version" ]] || fail 'verified version directory was removed after failed link switch'
ln -s "$root/usr/local/lib/relay-manager/versions/$version" "$root/usr/local/lib/relay-manager/current"
ln -s "$root/usr/local/lib/relay-manager/current/relay-manager.sh" "$root/usr/local/bin/relay-manager"

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

# Package install must require an outer fixed digest.
rc=0
update_install_manager_package "$package" "" "$built_pub" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'manager package install accepted a missing outer digest'

status=$(update_status_json)
assert_json "$status" '
  .manager.current_version=="'"$version"'" and
  .manager.command_link=="managed" and
  .manager.trusted_release_key.status=="present" and
  .remote_check.status=="not_performed"
'
verified=$(update_verify_current_manager)
assert_json "$verified" '.status=="verified" and .version=="'"$version"'" and .network_used==false'

pass 'Stage D signed package build, manifest/signature verification, trust pinning and idempotent install'
