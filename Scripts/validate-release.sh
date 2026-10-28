#!/usr/bin/env bash
# Runs every local release gate. Run it from a fresh clone before tagging.
set -euo pipefail

cd "$(dirname "$0")/.."

SWIFTCBORLD_MODULE_CACHE="${TMPDIR:-/tmp}/swift-cborld-module-cache"
mkdir -p "$SWIFTCBORLD_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$SWIFTCBORLD_MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTCBORLD_MODULE_CACHE"

Scripts/check-evidence.sh

swift package --disable-sandbox dump-package >/dev/null
swift format lint --strict --recursive Sources Tests Package.swift
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors \
  --explicit-target-dependency-import-check error
swift test --disable-sandbox -c release --disable-swift-testing
Scripts/public-api.sh
Scripts/check-coverage.sh --disable-sandbox

if command -v xcrun >/dev/null 2>&1 && xcrun --find docc >/dev/null 2>&1; then
  Scripts/build-docs.sh .build/docc-validation
fi

echo "Swift-CBORLD local release gates passed."
