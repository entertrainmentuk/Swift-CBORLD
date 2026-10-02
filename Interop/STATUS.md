# Interop Lab status

Updated 2026-09-27 for the `0.1.0` preview tree. “Current” here means evidence
retained in this repository, a public CI run identified by number and commit,
or explicitly bounded local development evidence. It does not predict what
later CI runs or future accelerator packages will demonstrate.

| Implementation or lane | Evidence state | Exact boundary |
| --- | --- | --- |
| Swift-CBORLD core | Source-present, build-validated, runtime-validated | Public CI run [34752516586](https://github.com/entertrainmentuk/Swift-CBORLD/actions/runs/34752516586) at commit `af20539` (2026-09-13) built with warnings as errors and passed 75 tests with 1 opt-in skip on macos-15 and ubuntu-24.04 with Swift 6.0.3. The current tree's 164 tests (1 opt-in skip) passed locally on macOS with Swift 6.4 and on Linux with Swift 6.2, including address and thread sanitizer runs on Linux; public CI has not yet run on this tree |
| Registry entries and processing models | Source-present, runtime-validated | Registry entries, processing models, codecs, and error names from the CBOR-LD 1.0 editor's draft at w3c/cbor-ld `992f9335703c`, covered by this package's own tests only; the pinned JavaScript reference predates processing models, and no independent implementation has been compared |
| Swift-CBORLD ↔ Rust corpus | Runtime-validated, byte-identical, Swift CPU performance-win | 11/11 recorded fixtures; in-process round-trip median on one macOS/arm64 setup; exact report retained under `reports/` |
| Digital Bazaar JavaScript | Source-present, runtime-validated, semantically-equivalent | Immutable comparator pin plus a retained dated 114/114 cross-decode snapshot; the current clean release does not rerun the JavaScript adapter |
| LDC Labs Rust | Source-present, build-validated, runtime-validated, byte-identical | Immutable source pin plus the recorded 11-fixture Swift/Rust run |
| Subfile Python | Source-present, runtime-validated, semantically-equivalent | Immutable comparator pin plus a retained dated 114/114 cross-decode snapshot; the current clean release does not rerun the Python adapter |
| Iridium Java | Source-present | Architecture/reference review in the mixed development workspace; not vendored, built, or executed by this release |
| fxamacker Go oracle | Source-present, runtime-validated | Immutable raw-CBOR oracle pin; retained snapshot records 63/64 RFC-valid vectors and one expected legacy rejection |
| anweiss CDDL oracle | Source-present | Immutable CDDL pin; no retained runtime result; the CDDL family remains unavailable without an injected oracle |
| Public `CBORLDCompute` contracts | Source-present, runtime-validated | 12 conceptual additions, exposed as 13 identifiers; the Swift suite covers the deterministic CPU references and shadow verification of every family, and receipts keep CPU and CPU-fallback execution distinct from accelerated parity |
| Swift-CBORLD plus SemanticCompute | Runtime-validated locally, unavailable publicly | Five adapter tests cover four bridged families and capability metadata in the excluded development tree; they do not prove Metal execution, public distribution, or speedup |
| SemanticCompute hardware track | Unavailable | No public SC-on/off crossover curves, signed `1.23.0` framework artifact, distributable XCFramework package, binary hash, or hardware-executed report is retained here |

The 2.22x recorded result belongs only to the Swift CPU versus Rust CPU lanes.
It is not SemanticCompute evidence.

Every comparator pin is public-CI-verified: run
[34751971440](https://github.com/entertrainmentuk/Swift-CBORLD/actions/runs/34751971440)
at commit `0493fd9` (2026-09-13) downloaded all five commit-addressed archives
and matched their recorded SHA-256 digests. The pins file is unchanged since,
and the workflow now repeats the check weekly. A verified pin proves that the
archived source is unchanged; it does not rerun that implementation.

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
