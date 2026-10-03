#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/testlib.sh"

root=$(new_test_root)
work=$(mktemp -d)
trap 'rm -rf "$root" "$work"' EXIT
export RM_ROOT="$root" RM_TEST_MODE=1

version=$(cat "$PROJECT_DIR/VERSION")
commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
priv="$work/release.key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$priv" >/dev/null 2>&1
mkdir "$work/out"
SOURCE_DATE_EPOCH=1700000000 "$PROJECT_DIR/tools/release/build-package.sh" \
  --version "$version" --commit "$commit" --signing-key "$priv" --out "$work/out" >"$work/package.json"

package=$(jq -r .package "$work/package.json")
package_sha=$(jq -r .sha256 "$work/package.json")
pub=$(jq -r .public_key "$work/package.json")
pub_sha=$(jq -r .public_key_sha256 "$work/package.json")

bootstrap="$work/bootstrap-$version.sh"
"$PROJECT_DIR/tools/release/build-bootstrap.sh" \
  --version "$version" \
  --package-url "https://example.invalid/releases/$version/relay-manager-$version.tar.gz" \
  --package-sha256 "$package_sha" \
  --public-key-url "https://example.invalid/releases/$version/RELEASE.pub.pem" \
  --public-key-sha256 "$pub_sha" \
  --out "$bootstrap" >/dev/null

bash -n "$bootstrap"
grep -Fq "ASTER_VERSION=$version" "$bootstrap" || fail 'bootstrap did not pin version'
grep -Fq "ASTER_PACKAGE_SHA256=$package_sha" "$bootstrap" || fail 'bootstrap did not pin package digest'
grep -Fq "ASTER_PUBLIC_KEY_SHA256=$pub_sha" "$bootstrap" || fail 'bootstrap did not pin public-key digest'
if grep -Eq '(/main/|/latest/|refs/heads/main)' "$bootstrap"; then
  fail 'bootstrap contains floating main/latest reference'
fi

fakebin="$work/fakebin"
mkdir "$fakebin"
cat >"$fakebin/curl" <<'FAKECURL'
#!/usr/bin/env bash
set -Eeuo pipefail
out='' url='' next_is_out=false
for arg in "$@"; do
  if [[ $next_is_out == true ]]; then out=$arg; next_is_out=false; continue; fi
  case "$arg" in
    --output) next_is_out=true ;;
    https://*) url=$arg ;;
  esac
done
[[ -n $out && -n $url ]] || exit 22
case "$url" in
  */RELEASE.pub.pem) cp -- "$FAKE_BOOTSTRAP_PUB" "$out" ;;
  */relay-manager-*.tar.gz) cp -- "$FAKE_BOOTSTRAP_PACKAGE" "$out" ;;
  *) exit 22 ;;
esac
FAKECURL
chmod 0755 "$fakebin/curl"

export FAKE_BOOTSTRAP_PACKAGE="$package" FAKE_BOOTSTRAP_PUB="$pub"
result=$(PATH="$fakebin:$PATH" "$bootstrap")
assert_json "$result" '.status=="installed" and .version=="'"$version"'"'
assert_eq "$root/usr/local/lib/relay-manager/versions/$version/relay-manager.sh" "$(readlink -f "$root/usr/local/bin/relay-manager")"
assert_eq "$pub_sha" "$(sha256sum "$root/etc/relay-manager/trusted-release.pem" | awk '{print $1}')" 'bootstrap trust anchor mismatch'

# Wrong package bytes must be rejected before extraction or installer execution.
printf x >>"$package"
rc=0
PATH="$fakebin:$PATH" "$bootstrap" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'bootstrap accepted a package with the wrong pinned hash'

# Generator refuses non-HTTPS/floating-style transport inputs.
rc=0
"$PROJECT_DIR/tools/release/build-bootstrap.sh" \
  --version "$version" --package-url "http://example.invalid/pkg" --package-sha256 "$package_sha" \
  --public-key-url "https://example.invalid/key" --public-key-sha256 "$pub_sha" --out "$work/bad.sh" >/dev/null 2>&1 || rc=$?
assert_eq 10 "$rc" 'bootstrap generator accepted non-HTTPS package URL'

pass 'Stage D fixed-version bootstrap pins package/key hashes and installs only after safe download checks'
