#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
unit_only=false
[[ ${1:-} == --unit-only ]] && unit_only=true

printf 'Relay Manager test runner\n'
printf 'Project: %s\n' "$PROJECT_DIR"

failures=0; passed=0; skipped=0
for test in "$TEST_DIR"/test_*.sh; do
  [[ $(basename "$test") == testlib.sh ]] && continue
  name=$(basename "$test")
  printf '\n== %s ==\n' "$name"
  if bash "$test"; then ((passed+=1)); else ((failures+=1)); fi
done

printf '\n== static checks ==\n'
syntax_failed=0
while IFS= read -r file; do
  if ! bash -n "$file"; then syntax_failed=1; fi
done < <(find "$PROJECT_DIR" -maxdepth 3 -type f -name '*.sh' -print | sort)
if ((syntax_failed==0)); then printf 'PASS: bash -n\n'; ((passed+=1)); else printf 'FAIL: bash -n\n'; ((failures+=1)); fi

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t shell_files < <(find "$PROJECT_DIR" -maxdepth 3 -type f -name '*.sh' -print | sort)
  if shellcheck -S error -x "${shell_files[@]}"; then printf 'PASS: shellcheck\n'; ((passed+=1)); else printf 'FAIL: shellcheck\n'; ((failures+=1)); fi
else
  printf 'SKIP: shellcheck not installed in this environment\n'; ((skipped+=1))
fi

printf '\nSummary: passed=%d failed=%d skipped=%d\n' "$passed" "$failures" "$skipped"
((failures==0))
