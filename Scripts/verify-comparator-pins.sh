#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in curl jq shasum tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: comparator verification requires $tool" >&2
    exit 1
  fi
done

SWIFTCBORLD_PIN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/swift-cborld-pins.XXXXXX")"
trap 'rm -rf "$SWIFTCBORLD_PIN_WORK"' EXIT

index=0
while IFS=$'\t' read -r name revision archive_url expected_sha; do
  if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: invalid immutable pin for $name" >&2
    exit 1
  fi

  archive="$SWIFTCBORLD_PIN_WORK/$index.tar.gz"
  curl --fail --location --silent --show-error --retry 3 \
    --output "$archive" "$archive_url"
  printf '%s  %s\n' "$expected_sha" "$archive" | shasum -a 256 -c -
  tar -tzf "$archive" >/dev/null
  printf 'verified %s at %s\n' "$name" "$revision"
  index=$((index + 1))
done < <(
  jq -r '.comparators[] | [.name, .revision, .archiveURL, .archiveSHA256] | @tsv' \
    Interop/comparators.json
)

test "$index" -gt 0
