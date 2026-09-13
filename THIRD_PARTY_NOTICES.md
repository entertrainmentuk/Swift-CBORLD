# Third-party notices

Swift-CBORLD is an independent Swift implementation. It is not endorsed by
Digital Bazaar, the W3C, the IETF, LDC Labs, Subfile, or the other projects
named below.

## Digital Bazaar `cborld`

- Project: <https://github.com/digitalbazaar/cborld>
- License: BSD-3-Clause
- Copyright: 2020-2026 Digital Bazaar, Inc.

Portions of the implementation, compatibility behavior, fixtures, and project
terminology originate from or are derived from the Digital Bazaar CBOR-LD
project. The complete BSD-3-Clause terms governing those portions are retained
in the repository's `LICENSE` file.

## LDC Labs `cbor-ld`

- Project: <https://github.com/ldclabs/cbor-ld>
- Compared version: 0.1.0
- License: MIT
- Copyright: 2026 LDC Labs

The small `cborld-cross-language.json` fixture records CBOR-LD bytes
independently asserted by this Rust implementation. No Rust source or binary is
distributed in this repository.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Subfile `cborld`

- Project: <https://github.com/subfile-llc/cborld>
- Compared version: 1.0.0
- License: BSD-3-Clause
- Copyright: 2020-2026 Digital Bazaar, Inc.; 2026 Subfile, LLC

The small `cborld-cross-language.json` fixture records CBOR-LD bytes
independently asserted by this Python implementation. No Python package source
or binary is distributed in this repository. Its BSD-3-Clause requirements are
compatible with, and retained by, this repository's BSD-3-Clause distribution.

## CBOR standards examples

- RFC 8949: <https://www.rfc-editor.org/rfc/rfc8949>
- Community test-vector project: <https://github.com/cbor/test-vectors>

`rfc8949-curated.json` is a small, deliberately varied selection of encoded
values used to test the package's CBOR reader, deterministic writer, malformed
input behavior, and indefinite-length policy. It is not a vendored copy of the
upstream test-vector repository.

## CBOR-LD specification

- Specification: <https://digitalbazaar.github.io/cbor-ld-spec/>

Specification names and protocol identifiers are used solely to describe
interoperability.
