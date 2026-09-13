#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SWIFTCBORLD_MODULE_CACHE="${TMPDIR:-/tmp}/swift-cborld-module-cache"
mkdir -p "$SWIFTCBORLD_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFTCBORLD_MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTCBORLD_MODULE_CACHE"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git ls-files | grep -E '(^|/)(\.build|\.swiftpm/xcode|node_modules|RUST|iridium-cbor-ld-main|coverage|target)(/|$)' >/dev/null; then
    echo "error: a forbidden build, vendor, or comparison path is tracked" >&2
    exit 1
  fi
fi

if grep -R -n -E '/Users/|/var/folders/' \
  --exclude-dir=.build --exclude-dir=.git Sources Tests Interop docs README.md 2>/dev/null; then
  echo "error: release files contain a machine-local absolute path" >&2
  exit 1
fi

find Interop -type f -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
jq -e . docs/interop-data.json >/dev/null
jq -e '.schemaVersion == 1 and (.implementations | length == 8)' \
  Interop/lab-status.json >/dev/null
cmp -s Interop/reports/interop-macos-arm64.json docs/interop-data.json || {
  echo "error: published interop data differs from the reviewed report" >&2
  exit 1
}

swift package --disable-sandbox dump-package >/dev/null
swift format lint --strict --recursive Sources Tests Package.swift
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test --disable-sandbox -c release --disable-swift-testing
mkdir -p .build/public-symbols
swift build --disable-sandbox --target CBORLD \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir \
  -Xswiftc .build/public-symbols
test -s .build/public-symbols/CBORLD.symbols.json

if command -v xcrun >/dev/null 2>&1 && xcrun --find docc >/dev/null 2>&1; then
  xcrun docc convert Sources/CBORLD/CBORLD.docc \
    --additional-symbol-graph-dir .build/public-symbols \
    --output-path .build/docc-validation \
    --hosting-base-path Swift-CBORLD/api \
    --warnings-as-errors \
    --fallback-display-name Swift-CBORLD \
    --fallback-bundle-identifier io.github.entertrainment.swift-cborld
fi

(cd Interop/reports && shasum -a 256 -c SHA256SUMS)
shasum -a 256 -c Interop/FIXTURE_SHA256SUMS

echo "Swift-CBORLD local release gates passed."
