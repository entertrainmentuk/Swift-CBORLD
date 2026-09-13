# Security policy

## Supported versions

Until the first preview tag is published, security fixes apply to the `main`
branch. After publication, the latest `0.x` preview is supported. Preview APIs
may change when a fix requires a safer contract.

## Reporting a vulnerability

Use the repository's private GitHub security-advisory flow. Do not disclose a
suspected vulnerability in a public issue before a fix or coordinated advisory
is available. Include the affected version or commit, a minimal reproducer,
expected and observed behavior, and any known impact.

If private advisories are temporarily unavailable, contact the repository owner
privately through the contact method shown on the GitHub organization profile.

## Trust boundary

Swift-CBORLD parses attacker-controlled bytes only within caller-selected
limits. Applications should configure conservative input, nesting, and
container bounds; reject duplicate map keys and indefinite-length items at
strict trust boundaries; pin dictionaries and remote contexts; and authenticate
transport digests in an enclosing protocol when origin matters.

The project does not claim that a digest authenticates a producer, that a
structural fingerprint proves RDF-semantic equivalence, or that a successful
CBOR scan constitutes CDDL validation.
