# SemanticCompute Live release check

Swift-CBORLD includes an opt-in test that sends a freshly encoded, pinned
CBOR-LD fixture to SemanticCompute Live for exact byte verification. The normal
package suite remains offline and has no SemanticCompute dependency.

The current beta endpoint executes the byte-diff CPU reference and returns a
digest-only receipt. This proves that the request executed through the service
and that the bytes matched; it is not evidence of Metal execution, producer
authentication, or a signed release artifact.

Run against a local beta service:

```bash
# In the SemanticCompute checkout:
swift build --product semanticcompute-live
SC_LIVE_TOKEN=local-test .build/debug/semanticcompute-live --port 8787

# In this Swift-CBORLD checkout:
SC_LIVE_URL=http://127.0.0.1:8787 \
SC_LIVE_TOKEN=local-test \
SC_LIVE_EXPECTED_ENGINE=1.22.1 \
swift test --filter SemanticComputeLiveTests
```

The test requires an HTTP 200 response whose receipt says
`executionStatus: executed`, identifies the expected runner, reports exact
compatibility, and declares a `digest-only` attestation. The
`SC_LIVE_EXPECTED_ENGINE` variable optionally pins the engine version. Set
`SC_LIVE_EXPECTED_TARGET` when using a runner other than the beta
`cpu-reference` target.

The same check runs in CI only on demand, through the `SemanticCompute Live`
workflow in `.github/workflows/semanticcompute-live.yml`. Store `SC_LIVE_URL`
and `SC_LIVE_TOKEN` as secrets of the `semanticcompute-live` environment, whose
protection rules can require a reviewer before the secrets are used. The
workflow's optional inputs set `SC_LIVE_EXPECTED_ENGINE` and
`SC_LIVE_EXPECTED_TARGET`, and an empty value leaves the corresponding check at
its default. The job fails when the URL secret is missing or the test skips,
so a passing run always means the service answered and the bytes matched.

Keep `SC_LIVE_TOKEN` in CI secrets; do not commit it or put it in a repository
manifest. A future signed-receipt gate must cryptographically verify the
signature against an explicitly trusted key. Merely receiving a non-empty
signature field will not count as authentication.
