#!/usr/bin/env bash
# Builds the DocC reference for both library modules into a site directory:
# CBORLD into <site>/api and CBORLDCompute into <site>/api-compute, hosted
# below the GitHub Pages path /Swift-CBORLD. Warnings fail the build.
#
#   Scripts/build-docs.sh <site directory>
set -euo pipefail

cd "$(dirname "$0")/.."

site="${1:?usage: Scripts/build-docs.sh <site directory>}"
scratch="$PWD/.build/docs"
graphs="$scratch/symbol-graphs"
mkdir -p "$graphs" "$site"

if command -v xcrun >/dev/null 2>&1; then
  docc=(xcrun docc)
else
  docc=(docc)
fi

# Building CBORLDCompute also builds CBORLD, so one build emits both graphs.
swift build --disable-sandbox --scratch-path "$scratch" --target CBORLDCompute \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir \
  -Xswiftc "$graphs" >/dev/null

for module in CBORLD CBORLDCompute; do
  case "$module" in
  CBORLD)
    directory=api
    name=Swift-CBORLD
    identifier=io.github.entertrainment.swift-cborld
    ;;
  CBORLDCompute)
    directory=api-compute
    name="Swift-CBORLD Compute"
    identifier=io.github.entertrainment.swift-cborld.compute
    ;;
  esac
  # Each catalog receives only its own module's graphs, including the graphs
  # of its extensions to other modules.
  module_graphs="$scratch/$module"
  rm -rf "$module_graphs"
  mkdir -p "$module_graphs"
  find "$graphs" \( -name "$module.symbols.json" -o -name "$module@*.symbols.json" \) \
    -exec cp {} "$module_graphs" \;
  test -s "$module_graphs/$module.symbols.json"

  "${docc[@]}" convert "Sources/$module/$module.docc" \
    --additional-symbol-graph-dir "$module_graphs" \
    --output-path "$site/$directory" \
    --hosting-base-path "Swift-CBORLD/$directory" \
    --warnings-as-errors \
    --fallback-display-name "$name" \
    --fallback-bundle-identifier "$identifier"
done
