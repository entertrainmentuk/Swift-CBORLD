# Source provenance

This record describes the reviewed classes of material in the Swift-CBORLD
preview tree. It is an engineering provenance record, not a claim of exclusive
authorship or legal advice.

| Path | Classification | Distribution basis |
| --- | --- | --- |
| `Sources/CBORLD/` | Native Swift implementation and subsequent Swift refactoring; protocol behavior and portions of logic are informed by or adapted from Digital Bazaar `cborld` | Repository BSD-3-Clause license with Digital Bazaar notice retained |
| `Tests/CBORLDTests/*.swift` | Swift test code authored for this implementation | Repository BSD-3-Clause license |
| `Tests/CBORLDTests/Fixtures/upstream-digitalbazaar/` | Four small compatibility resources retained from the mixed Digital Bazaar development tree | Digital Bazaar BSD-3-Clause notice retained in `LICENSE` and `THIRD_PARTY_NOTICES.md` |
| `Tests/CBORLDTests/Fixtures/cborld-cross-language.json` | Curated envelope bytes independently asserted by the named Rust and Python sources | Repository BSD-3-Clause compilation; source licenses recorded per entry and in `THIRD_PARTY_NOTICES.md` |
| `Tests/CBORLDTests/Fixtures/rfc8949-curated.json` | Small selection of public CBOR standard examples | Attribution in the fixture and `THIRD_PARTY_NOTICES.md` |
| `Schemas/` | Small structural CDDL gates written for this implementation from the public CBOR-LD envelope contract | Repository BSD-3-Clause license; specification attribution retained |
| `Interop/reports/` | Locally generated measurement evidence with machine-local paths removed | Repository BSD-3-Clause license; comparator identity and measurement boundary retained |
| `Interop/schemas/`, `Interop/lab-status.json`, and challenge documentation | Public evidence vocabulary, portable result contracts, and bounded status records authored for this release | Repository BSD-3-Clause license; named external implementations are linked, not redistributed |
| Documentation, CI, scripts, and site | Release engineering and explanatory material for Swift-CBORLD | Repository BSD-3-Clause license |

Excluded vendor and reference trees—including Digital Bazaar JavaScript source,
Rust, Python, Go, Java, downloaded modules, and SemanticCompute—are not part of
this repository. They may be resolved only as temporary, pinned validation
inputs after their immutable revisions, licenses, and archive checksums are
recorded.

The initial preview deliberately uses BSD-3-Clause for the complete tree. A
future per-file Apache-2.0 option requires a separate authorship audit and must
not remove or obscure any BSD-licensed provenance.
