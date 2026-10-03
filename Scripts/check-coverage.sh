#!/usr/bin/env bash
# Runs the test suite with coverage and enforces minimum line coverage for the
# package's own sources, per module and per file. The report is the JSON that
# `swift test --enable-code-coverage` exports, so the check needs only jq and
# works on every platform SwiftPM supports.
#
#   Scripts/check-coverage.sh [extra swift test arguments]
set -euo pipefail

cd "$(dirname "$0")/.."

# Minimum line coverage, in percent.
MODULE_MINIMUM_CBORLD=90
MODULE_MINIMUM_CBORLDCOMPUTE=90
FILE_MINIMUM=80

swift test --enable-code-coverage --disable-swift-testing "$@" >/dev/null
report="$(swift test --show-codecov-path "$@")"

rows="$(jq -r '
  .data[0].files[]
  | select(.filename | test("/Sources/"))
  | [(.filename | sub(".*/Sources/"; "")), .summary.lines.count, .summary.lines.covered]
  | @tsv' "$report")"

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

for module in CBORLD CBORLDCompute; do
  case "$module" in
  CBORLD) minimum=$MODULE_MINIMUM_CBORLD ;;
  CBORLDCompute) minimum=$MODULE_MINIMUM_CBORLDCOMPUTE ;;
  esac
  percent=$(awk -F'\t' -v module="$module/" '
    index($1, module) == 1 { count += $2; covered += $3 }
    END { printf "%.2f", count ? 100 * covered / count : 100 }' <<<"$rows")
  printf '%-48s %7s%% (minimum %s%%)\n' "$module total" "$percent" "$minimum"
  if awk -v p="$percent" -v m="$minimum" 'BEGIN { exit !(p < m) }'; then
    echo "error: $module line coverage $percent% is below $minimum%." >&2
    status=1
  fi
done
exit "$status"
