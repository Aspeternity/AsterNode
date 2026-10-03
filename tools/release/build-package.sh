#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)

usage() {
  cat <<'TXT'
Build a signed AsterNode/Relay Manager release package.

Usage:
  tools/release/build-package.sh --version VERSION --commit GIT_SHA --signing-key PRIVATE_KEY --out DIR

Environment:
  SOURCE_DATE_EPOCH  Optional. Set for repeatable timestamps/tar metadata.
TXT
}

version='' commit='' signing_key='' out=''
while (($#)); do
  case "$1" in
    --version) version=${2:-}; shift 2 ;;
    --commit) commit=${2:-}; shift 2 ;;
    --signing-key) signing_key=${2:-}; shift 2 ;;
    --out) out=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 10 ;;
  esac
done

[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || { printf 'Invalid version\n' >&2; exit 10; }
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { printf 'Commit must be a 40-char lowercase Git SHA\n' >&2; exit 10; }
[[ -n $out && -d $out ]] || { printf 'Output directory must already exist\n' >&2; exit 10; }
[[ -f $signing_key && ! -L $signing_key ]] || { printf 'Signing key must be a regular file\n' >&2; exit 10; }
command -v jq >/dev/null && command -v openssl >/dev/null && command -v sha256sum >/dev/null && command -v tar >/dev/null || {
  printf 'Missing jq/openssl/sha256sum/tar\n' >&2; exit 10;
}
openssl pkey -in "$signing_key" -noout >/dev/null 2>&1 || { printf 'Invalid private signing key\n' >&2; exit 10; }
[[ $(cat "$PROJECT_DIR/VERSION") == "$version" ]] || { printf 'VERSION file does not match --version\n' >&2; exit 10; }

epoch=${SOURCE_DATE_EPOCH:-$(date +%s)}
[[ $epoch =~ ^[0-9]+$ ]] || { printf 'SOURCE_DATE_EPOCH must be an integer\n' >&2; exit 10; }
built_at=$(date -u -d "@$epoch" +'%Y-%m-%dT%H:%M:%SZ')
root_name="relay-manager-$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"; root="$stage/$root_name"
mkdir -p "$root"

copy_items=(VERSION README.md CHANGELOG.md install.sh relay-manager.sh diagnostics.sh lib protocols compat templates tests docs tools)
for item in "${copy_items[@]}"; do
  [[ -e "$PROJECT_DIR/$item" ]] || { printf 'Required release path missing: %s\n' "$item" >&2; exit 10; }
  cp -a "$PROJECT_DIR/$item" "$root/"
done

if find "$root" -type l -print -quit | grep -q .; then
  printf 'Release payload contains a symlink; refusing package build\n' >&2
  exit 10
fi
find "$root" -type f -exec chmod go-w {} +

entries="$tmp/entries.ndjson"
: >"$entries"
while IFS= read -r -d '' file; do
  rel=${file#"$root/"}
  case "$rel" in MANIFEST.json|SHA256SUMS|RELEASE.sig) continue;; esac
  sha=$(sha256sum "$file" | awk '{print $1}')
  size=$(stat -c '%s' "$file")
  mode=$(stat -c '%a' "$file")
  jq -cn --arg path "$rel" --arg sha "$sha" --argjson size "$size" --arg mode "$mode"     '{path:$path,sha256:$sha,size:$size,mode:$mode}' >>"$entries"
done < <(find "$root" -type f -print0 | sort -z)

files=$(jq -s 'sort_by(.path)' "$entries")
default_core=$(jq -r .default_core_version "$PROJECT_DIR/compat/compatibility.json")
architectures=$(jq -c --arg v "$default_core" '.core.xray[$v].assets|keys|sort' "$PROJECT_DIR/compat/compatibility.json")
profiles=$(jq -c '.client_profiles|keys|sort' "$PROJECT_DIR/compat/compatibility.json")
if [[ $version == *-* ]]; then prerelease=true; else prerelease=false; fi

jq -n   --arg version "$version"   --arg commit "$commit"   --arg built "$built_at"   --arg core "$default_core"   --argjson prerelease "$prerelease"   --argjson arch "$architectures"   --argjson profiles "$profiles"   --argjson files "$files"   '{
    release_format:1,
    project:"relay-manager",
    product:"AsterNode",
    version:$version,
    commit_sha:$commit,
    prerelease:$prerelease,
    built_at:$built,
    state_schema:1,
    compatibility_document:"docs/COMPATIBILITY.md",
    supported:{
      systems:["Debian 12","Debian 13","Ubuntu 22.04","Ubuntu 24.04"],
      architectures:$arch,
      evidence:"Target matrix only; verified combinations are documented in docs/COMPATIBILITY.md"
    },
    default_core_version:$core,
    client_profiles:$profiles,
    files:$files
  }' >"$root/MANIFEST.json"
chmod 0644 "$root/MANIFEST.json"

(
  cd "$root"
  {
    printf '%s  %s\n' "$(sha256sum MANIFEST.json | awk '{print $1}')" "./MANIFEST.json"
    jq -r '.files[].path' MANIFEST.json | while IFS= read -r rel; do
      printf '%s  ./%s\n' "$(sha256sum "$rel" | awk '{print $1}')" "$rel"
    done
  } | sort -k2 >SHA256SUMS
)
chmod 0644 "$root/SHA256SUMS"
openssl dgst -sha256 -sign "$signing_key" -out "$root/RELEASE.sig" "$root/SHA256SUMS"
chmod 0644 "$root/RELEASE.sig"

package="$out/$root_name.tar.gz"
tmp_package="$package.tmp"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -C "$stage" -czf "$tmp_package" "$root_name"
mv -f "$tmp_package" "$package"
sha256sum "$package" | awk '{print $1"  "$2}' >"$package.sha256"
openssl pkey -in "$signing_key" -pubout -out "$out/RELEASE.pub.pem" >/dev/null 2>&1
chmod 0644 "$out/RELEASE.pub.pem"
sha256sum "$out/RELEASE.pub.pem" >"$out/RELEASE.pub.pem.sha256"

jq -n   --arg package "$package"   --arg sha "$(sha256sum "$package" | awk '{print $1}')"   --arg public_key "$out/RELEASE.pub.pem"   --arg public_key_sha "$(sha256sum "$out/RELEASE.pub.pem" | awk '{print $1}')"   '{package:$package,sha256:$sha,public_key:$public_key,public_key_sha256:$public_key_sha}'
