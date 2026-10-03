#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat <<'TXT'
Generate a fixed-version AsterNode bootstrap script.

Usage:
  tools/release/build-bootstrap.sh \
    --version VERSION \
    --package-url HTTPS_URL --package-sha256 SHA256 \
    --public-key-url HTTPS_URL --public-key-sha256 SHA256 \
    --out FILE

The generated bootstrap is version-pinned. It never follows floating main/latest.
TXT
}

version='' package_url='' package_sha='' key_url='' key_sha='' out=''
while (($#)); do
  case "$1" in
    --version) version=${2:-}; shift 2 ;;
    --package-url) package_url=${2:-}; shift 2 ;;
    --package-sha256) package_sha=${2:-}; shift 2 ;;
    --public-key-url) key_url=${2:-}; shift 2 ;;
    --public-key-sha256) key_sha=${2:-}; shift 2 ;;
    --out) out=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 10 ;;
  esac
done

[[ $version =~ ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$ ]] || { printf 'Invalid version\n' >&2; exit 10; }
[[ $package_url == https://* && $package_url != *$'\n'* && $package_url != *$'\r'* ]] || { printf 'Package URL must be fixed HTTPS\n' >&2; exit 10; }
[[ $key_url == https://* && $key_url != *$'\n'* && $key_url != *$'\r'* ]] || { printf 'Public-key URL must be fixed HTTPS\n' >&2; exit 10; }
[[ $package_sha =~ ^[0-9a-fA-F]{64}$ && $key_sha =~ ^[0-9a-fA-F]{64}$ ]] || { printf 'SHA-256 values must be 64 hex chars\n' >&2; exit 10; }
[[ -n $out ]] || { printf 'Missing --out\n' >&2; exit 10; }
[[ ! -L $out ]] || { printf 'Output path must not be a symlink\n' >&2; exit 10; }
mkdir -p "$(dirname "$out")"

cat >"$out" <<BOOT
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ASTER_VERSION=$(printf '%q' "$version")
ASTER_PACKAGE_URL=$(printf '%q' "$package_url")
ASTER_PACKAGE_SHA256=$(printf '%q' "${package_sha,,}")
ASTER_PUBLIC_KEY_URL=$(printf '%q' "$key_url")
ASTER_PUBLIC_KEY_SHA256=$(printf '%q' "${key_sha,,}")
ASTER_PACKAGE_MAX_BYTES=67108864
ASTER_ARCHIVE_MAX_ENTRIES=2000

die() { printf '[AsterNode bootstrap] %s\\n' "\$*" >&2; exit 10; }
need() { command -v "\$1" >/dev/null 2>&1 || die "missing command: \$1"; }
for c in curl sha256sum tar mktemp stat openssl; do need "\$c"; done

tmp=\$(mktemp -d)
trap 'rm -rf "\$tmp"' EXIT HUP INT TERM
package="\$tmp/relay-manager.tar.gz"
pub="\$tmp/RELEASE.pub.pem"
extract="\$tmp/extract"
mkdir "\$extract"

fetch() {
  local url=\$1 dst=\$2
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 2 --connect-timeout 10 --max-time 180 --output "\$dst" "\$url"
}

printf '[AsterNode bootstrap] fetching fixed version %s\\n' "\$ASTER_VERSION" >&2
fetch "\$ASTER_PACKAGE_URL" "\$package" || { printf '[AsterNode bootstrap] package download failed\\n' >&2; exit 30; }
fetch "\$ASTER_PUBLIC_KEY_URL" "\$pub" || { printf '[AsterNode bootstrap] public-key download failed\\n' >&2; exit 30; }

[[ \$(stat -c '%s' "\$package") -gt 0 && \$(stat -c '%s' "\$package") -le \$ASTER_PACKAGE_MAX_BYTES ]] || die 'package size outside bootstrap limit'
[[ \$(sha256sum "\$package" | awk '{print \$1}') == "\$ASTER_PACKAGE_SHA256" ]] || die 'package SHA-256 mismatch'
[[ \$(sha256sum "\$pub" | awk '{print \$1}') == "\$ASTER_PUBLIC_KEY_SHA256" ]] || die 'release public-key SHA-256 mismatch'
[[ -f \$pub && ! -L \$pub ]] || die 'release public key is not a regular file'
openssl pkey -pubin -in "\$pub" -noout >/dev/null 2>&1 || die 'release public key format invalid'

list=\$(tar -tzf "\$package") || die 'cannot list release archive'
count=\$(printf '%s\\n' "\$list" | awk 'NF{c++} END{print c+0}')
((count>0 && count<=ASTER_ARCHIVE_MAX_ENTRIES)) || die 'archive entry count outside limit'
dup=\$(printf '%s\\n' "\$list" | sed '/^\$/d' | sort | uniq -d | head -n1)
[[ -z \$dup ]] || die "duplicate archive path: \$dup"
expected_root="relay-manager-\$ASTER_VERSION"
while IFS= read -r entry; do
  [[ -n \$entry ]] || continue
  clean=\${entry#./}; clean=\${clean%/}
  [[ -n \$clean ]] || die 'empty archive path'
  [[ \$clean != /* && \$clean != ../* && \$clean != *'/../'* && \$clean != *'/..' &&
     \$clean != *\$'\\n'* && \$clean != *\$'\\r'* && \$clean != *\$'\\t'* && \$clean != *'\\\\'* ]] ||
    die "unsafe archive path: \$entry"
  top=\${clean%%/*}
  [[ \$top == "\$expected_root" ]] || die "archive root is not fixed version: \$top"
done <<<"\$list"
if tar -tvzf "\$package" | awk '\$1 !~ /^[-d]/ {bad=1} END{exit bad?0:1}'; then
  die 'archive contains links/devices/special entries'
fi

tar --no-same-owner -xzf "\$package" -C "\$extract" || die 'archive extraction failed'
root="\$extract/\$expected_root"
[[ -f \$root/install.sh && ! -L \$root/install.sh && -x \$root/install.sh ]] || die 'verified package is missing install.sh'

"\$root/install.sh" --package "\$package" --sha256 "\$ASTER_PACKAGE_SHA256" --trusted-key "\$pub"
printf '[AsterNode bootstrap] fixed version %s installed after hash + signed-manifest verification\\n' "\$ASTER_VERSION" >&2
BOOT

chmod 0755 "$out"
printf '%s\n' "$out"
