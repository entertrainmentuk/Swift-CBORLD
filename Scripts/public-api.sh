#!/usr/bin/env bash
# Lists every public declaration of the CBORLD and CBORLDCompute modules and
# compares the listing with the checked-in baseline under API/.
#
# Each line holds a symbol's kind, path, and complete declaration, including
# parameter and return types, so any signature change appears in the diff.
# Members that the standard library or Foundation synthesize through protocol
# extensions are omitted: they are not API decisions of this package, and
# their spelling varies between toolchains. For the same reason `@Sendable`
# is removed from closure types, which some toolchains do not print.
#
#   Scripts/public-api.sh           fail if the public API differs from API/
#   Scripts/public-api.sh --update  accept the current public API
#
# Before 1.0 a breaking change is allowed, but it must be intentional: update
# the baseline in the same change and describe it in CHANGELOG.md.
set -euo pipefail

cd "$(dirname "$0")/.."

modules=(CBORLD CBORLDCompute)
# A separate scratch path keeps these flags from invalidating ordinary builds.
# Graphs persist between runs because an up-to-date build does not rewrite
# them.
scratch="$PWD/.build/public-api"
graphs="$scratch/symbol-graphs"
mkdir -p "$graphs" API

for module in "${modules[@]}"; do
  swift build --disable-sandbox --scratch-path "$scratch" --target "$module" \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir \
    -Xswiftc "$graphs" >/dev/null
done

listing() {
  local module="$1"
  # A module's own graph plus the graphs of its extensions to other modules.
  find "$graphs" -name "${module}.symbols.json" -o -name "${module}@*.symbols.json" |
    sort |
    xargs -I{} jq -r '
      .symbols[]
      | select(.accessLevel == "public" or .accessLevel == "open")
      | select(.identifier.precise | contains("::SYNTHESIZED::") | not)
      | [.kind.identifier, (.pathComponents | join(".")),
         (.declarationFragments | map(.spelling) | join("") | gsub("@Sendable "; ""))]
      | join("\t")' {} |
    LC_ALL=C sort -u
}

status=0
for module in "${modules[@]}"; do
  baseline="API/${module}.txt"
  current="$scratch/${module}.txt"
  listing "$module" >"$current"
  if [[ "${1:-}" == "--update" ]]; then
    cp "$current" "$baseline"
    echo "Updated $baseline ($(wc -l <"$baseline" | tr -d ' ') public symbols)."
  elif ! diff -u "$baseline" "$current"; then
    echo "error: the public API of $module differs from $baseline." >&2
    echo "Run Scripts/public-api.sh --update if the change is intentional." >&2
    status=1
  fi
done
exit "$status"
