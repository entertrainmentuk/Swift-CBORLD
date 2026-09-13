# Interop Lab status

Updated 2026-09-13 for the `0.1.0` release-candidate tree. “Current” here means
evidence retained in this repository or explicitly bounded local development
evidence. It does not predict what public CI or future accelerator packages
will demonstrate.

| Implementation or lane | Evidence state | Exact boundary |
| --- | --- | --- |
| Swift-CBORLD core | Source-present, build-validated, runtime-validated | Dependency-free Swift core; 74 release tests passed locally on macOS; public macOS and Linux CI pending |
| Swift-CBORLD ↔ Rust corpus | Runtime-validated, byte-identical, Swift CPU performance-win | 11/11 recorded fixtures; in-process round-trip median on one macOS/arm64 setup; exact report retained under `reports/` |
| Digital Bazaar JavaScript | Source-present | Immutable comparator pin and retained compatibility vectors; current clean release does not execute the JavaScript package |
| LDC Labs Rust | Source-present, build-validated, runtime-validated, byte-identical | Immutable source pin plus the recorded 11-fixture Swift/Rust run |
| Subfile Python | Source-present | Immutable comparator pin and independently asserted retained vectors; current clean release does not execute the package |
| Iridium Java | Source-present | Architecture/reference review in the mixed development workspace; not vendored, built, or executed by this release |
| fxamacker Go oracle | Source-present | Immutable raw-CBOR oracle pin; no retained runtime result yet |
| anweiss CDDL oracle | Source-present | Immutable CDDL pin; no retained runtime result; the core CDDL family remains unavailable without an injected oracle |
| Public CBORLD compute contracts | Source-present, runtime-validated | 12 conceptual additions, exposed as 13 identifiers; deterministic CPU references are covered by the Swift suite |
| Swift-CBORLD plus SemanticCompute | Runtime-validated locally, unavailable publicly | Five adapter tests cover four bridged families and capability metadata in the excluded development tree; they do not prove Metal execution, public distribution, or speedup |
| SemanticCompute hardware track | Unavailable | No public SC-on/off crossover curves, signed `1.23.0` framework artifact, distributable XCFramework package, binary hash, or hardware-executed report is retained here |

The 2.22x recorded result belongs only to the Swift CPU versus Rust CPU lanes.
It is not SemanticCompute evidence.

The machine-readable counterpart is [`lab-status.json`](lab-status.json). A
future measurement must use [`schemas/lab-result.schema.json`](schemas/lab-result.schema.json)
and must preserve unavailable lanes instead of silently replacing them with a
CPU fallback.
