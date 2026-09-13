# Interop Lab status

Updated 2026-09-13 for the `0.1.0` release-candidate tree. “Current” here means
evidence retained in this repository or explicitly bounded local development
evidence. It does not predict what public CI or future accelerator packages
will demonstrate.

| Implementation or lane | Evidence state | Exact boundary |
| --- | --- | --- |
| Swift-CBORLD core | Source-present, build-validated, runtime-validated | Dependency-free Swift core; 74 release tests passed locally on macOS; public macOS and Linux CI pending |
| Swift-CBORLD ↔ Rust corpus | Runtime-validated, byte-identical, Swift CPU performance-win | 11/11 recorded fixtures; in-process round-trip median on one macOS/arm64 setup; exact report retained under `reports/` |
| Digital Bazaar JavaScript | Source-present, runtime-validated, semantically-equivalent | Immutable comparator pin plus a retained dated 114/114 cross-decode snapshot; the current clean release does not rerun the JavaScript adapter |
| LDC Labs Rust | Source-present, build-validated, runtime-validated, byte-identical | Immutable source pin plus the recorded 11-fixture Swift/Rust run |
| Subfile Python | Source-present, runtime-validated, semantically-equivalent | Immutable comparator pin plus a retained dated 114/114 cross-decode snapshot; the current clean release does not rerun the Python adapter |
| Iridium Java | Source-present | Architecture/reference review in the mixed development workspace; not vendored, built, or executed by this release |
| fxamacker Go oracle | Source-present, runtime-validated | Immutable raw-CBOR oracle pin; retained snapshot records 63/64 RFC-valid vectors and one expected legacy rejection |
| anweiss CDDL oracle | Source-present | Immutable CDDL pin; no retained runtime result; the core CDDL family remains unavailable without an injected oracle |
| Public CBORLD compute contracts | Source-present, runtime-validated | 12 conceptual additions, exposed as 13 identifiers; deterministic CPU references are covered by the Swift suite |
| Swift-CBORLD plus SemanticCompute | Runtime-validated locally, unavailable publicly | Five adapter tests cover four bridged families and capability metadata in the excluded development tree; they do not prove Metal execution, public distribution, or speedup |
| SemanticCompute hardware track | Unavailable | No public SC-on/off crossover curves, signed `1.23.0` framework artifact, distributable XCFramework package, binary hash, or hardware-executed report is retained here |

The 2.22x recorded result belongs only to the Swift CPU versus Rust CPU lanes.
It is not SemanticCompute evidence.

The scrubbed machine-readable cross-language snapshot is retained as
[`reports/interop-macos-arm64.json`](reports/interop-macos-arm64.json), with
the exact eight-case input corpus at [`fixtures/cases.json`](fixtures/cases.json).
It records 114/114 successful cross-decodes: six four-way fixtures at 16/16
and two legacy three-way fixtures at 9/9. Its generated site copy is checked
for exact identity during release validation. This is retained local runtime
evidence, not a claim that the clean release currently rebuilds or reruns every
external adapter.

The machine-readable counterpart is [`lab-status.json`](lab-status.json). A
future measurement must use [`schemas/lab-result.schema.json`](schemas/lab-result.schema.json)
and must preserve unavailable lanes instead of silently replacing them with a
CPU fallback.
