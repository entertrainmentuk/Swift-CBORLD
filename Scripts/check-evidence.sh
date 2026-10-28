#!/usr/bin/env bash
# Checks the retained release evidence and repository hygiene without building
# anything: JSON validity, the Interop status vocabulary, comparator pins,
# report and fixture checksums, and tracked or machine-local paths.
#
#   Scripts/check-evidence.sh
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in jq shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: evidence checks require $tool" >&2
    exit 1
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git ls-files | grep -E '(^|/)(\.build|\.swiftpm/xcode|node_modules|RUST|iridium-cbor-ld-main|coverage|target)(/|$)' >/dev/null; then
    echo "error: a forbidden build, vendor, or comparison path is tracked" >&2
    exit 1
  fi
fi

# The brackets keep this script from matching its own patterns.
if grep -R -n -E '/[U]sers/|/var/[f]olders/' \
  --exclude-dir=.build --exclude-dir=.git \
  Sources Tests Interop docs API Scripts ./*.md 2>/dev/null; then
  echo "error: release files contain a machine-local absolute path" >&2
  exit 1
fi

find Interop -type f -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
jq -e . docs/interop-data.json >/dev/null

# The status file must use exactly the keys and claim vocabulary that its
# schema defines.
jq -e --slurpfile schema Interop/schemas/lab-status.schema.json '
  def exactly($spec):
    keys as $present
    | ($present - ($spec.properties | keys) | length == 0)
      and all($spec.required[]; IN($present[]));
  ($schema[0].properties.implementations.items) as $item
  | ($item.properties.claims.items) as $claim
  | .schemaVersion == 1
    and (.updatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (.implementations | length == 8)
    and ([.implementations[].id] | length == (unique | length))
    and all(.implementations[];
      exactly($item)
      and (.id | test("^[a-z0-9-]+$"))
      and (.claims | length > 0)
      and all(.claims[];
        exactly($claim)
        and (.classification | IN($claim.properties.classification.enum[]))
        and (.scope | length > 0)
        and (.evidence | length > 0)))
' Interop/lab-status.json >/dev/null || {
  echo "error: Interop/lab-status.json does not match its schema vocabulary" >&2
  exit 1
}

# Every comparator must be pinned to an immutable revision and archive digest.
jq -e '
  .schemaVersion == 1
  and (.comparators | length > 0)
  and all(.comparators[];
    . as $pin
    | ($pin.revision | test("^[0-9a-f]{40}$"))
    and ($pin.archiveSHA256 | test("^[0-9a-f]{64}$"))
    and ($pin.archiveURL | endswith($pin.revision)))
' Interop/comparators.json >/dev/null || {
  echo "error: Interop/comparators.json contains a mutable or malformed pin" >&2
  exit 1
}

cmp -s Interop/reports/interop-macos-arm64.json docs/interop-data.json || {
  echo "error: published interop data differs from the reviewed report" >&2
  exit 1
}

(cd Interop/reports && shasum -a 256 -c SHA256SUMS)
shasum -a 256 -c Interop/FIXTURE_SHA256SUMS

echo "Evidence and repository hygiene checks passed."
