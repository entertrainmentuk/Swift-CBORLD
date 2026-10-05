#!/usr/bin/env bash
# Runs the test suite with coverage and enforces minimum line coverage for the
# package's own sources, per module and per file. The report is exported with
# llvm-cov from every test bundle, because SwiftPM's own export can omit all
# but one bundle when a package has several test targets.
#
#   Scripts/check-coverage.sh [extra swift test arguments]
set -euo pipefail

cd "$(dirname "$0")/.."

# Minimum line coverage, in percent.
MODULE_MINIMUM_CBORLD=90
MODULE_MINIMUM_CBORLDCOMPUTE=90
MODULE_MINIMUM_CBORLDCOMMANDLINE=90
FILE_MINIMUM=80

swift test --enable-code-coverage --disable-swift-testing "$@" >/dev/null
codecov="$(dirname "$(swift test --show-codecov-path "$@")")"
products="$(dirname "$codecov")"

# A test bundle is a directory on Apple platforms and an executable elsewhere.
objects=()
for bundle in "$products"/*.xctest; do
  if [[ -d "$bundle/Contents/MacOS" ]]; then
    objects+=("$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
  else
    objects+=("$bundle")
  fi
done
if [[ ${#objects[@]} -eq 0 ]]; then
  echo "error: no test bundles found in $products." >&2
  exit 1
fi
arguments=("${objects[0]}")
for object in "${objects[@]:1}"; do arguments+=(-object "$object"); done
if command -v xcrun >/dev/null 2>&1; then
  llvm_cov=(xcrun llvm-cov)
else
  llvm_cov=(llvm-cov)
fi

rows="$("${llvm_cov[@]}" export -summary-only \
  -instr-profile "$codecov/default.profdata" "${arguments[@]}" |
  jq -r '
    .data[0].files[]
    | select(.filename | test("/Sources/"))
    | [(.filename | sub(".*/Sources/"; "")), .summary.lines.count, .summary.lines.covered]
    | @tsv')"

status=0
printf '%-48s %8s\n' "File" "Lines"
while IFS=$'\t' read -r file count covered; do
  percent=$(awk -v c="$covered" -v n="$count" 'BEGIN { printf "%.2f", n ? 100 * c / n : 100 }')
  printf '%-48s %7s%%\n' "$file" "$percent"
  if awk -v p="$percent" -v m="$FILE_MINIMUM" 'BEGIN { exit !(p < m) }'; then
    echo "error: $file line coverage $percent% is below $FILE_MINIMUM%." >&2
    status=1
  fi
done <<<"$rows"

for module in CBORLD CBORLDCompute CBORLDCommandLine; do
  case "$module" in
  CBORLD) minimum=$MODULE_MINIMUM_CBORLD ;;
  CBORLDCompute) minimum=$MODULE_MINIMUM_CBORLDCOMPUTE ;;
  CBORLDCommandLine) minimum=$MODULE_MINIMUM_CBORLDCOMMANDLINE ;;
  esac
  # A module missing from the report must fail rather than count as covered.
  percent=$(awk -F'\t' -v module="$module/" '
    index($1, module) == 1 { count += $2; covered += $3 }
    END { printf "%.2f", count ? 100 * covered / count : -1 }' <<<"$rows")
  if [[ "$percent" == "-1.00" ]]; then
    echo "error: the coverage report has no lines from $module." >&2
    status=1
    continue
  fi
  printf '%-48s %7s%% (minimum %s%%)\n' "$module total" "$percent" "$minimum"
  if awk -v p="$percent" -v m="$minimum" 'BEGIN { exit !(p < m) }'; then
    echo "error: $module line coverage $percent% is below $minimum%." >&2
    status=1
  fi
done
exit "$status"
