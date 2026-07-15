# Security

`capa_authgate` is a demonstration application, not a cryptographic
library. It composes `capa_jwt` (HS256), `capa_uuid`, and `capa_base64`,
each **verified, not audited** (see each library's own SECURITY.md). Read
the [Honest posture](./README.md#honest-posture) in the README before
relying on it for anything security-critical.

## Verifying the signature of a release

Published release tags are GPG-signed. The publisher's key:

- **Name**: Nelson Duarte (capa-language publisher)
- **Email**: nelson.duarte31@gmail.com
- **Fingerprint**:
  `6C1D 222D 491F B880 31E0  41A5 36CF B426 101A A24B`
- **Public key**: [`publisher.asc`](./publisher.asc) in this
  repository.

The full 40-character fingerprint without spaces:
`6C1D222D491FB88031E041A536CFB426101AA24B`. Use this exact form in a
`capa.toml`'s `verify_key` field (spaces and colons are also accepted;
the manifest parser normalises).

### Import the key

Out-of-band trust path (recommended): clone this repository, inspect
`publisher.asc`, then:

```bash
gpg --import publisher.asc
gpg --fingerprint nelson.duarte31@gmail.com
# Verify the printed fingerprint matches the one above.
```

### Verify a tag manually

```bash
git clone https://github.com/nelsonduarte/capa_authgate
cd capa_authgate
git verify-tag v0.1.0
# Look for: "Good signature from "Nelson Duarte <...>" [ultimate]"
# and the fingerprint above.
```

## The dependency supply chain

`capa_authgate` pins its three runtime dependencies by tag and
`verify_key` in [`capa.toml`](./capa.toml):

```toml
[dependencies.capa_jwt]
git = "https://github.com/nelsonduarte/capa_jwt"
tag = "v0.1.0"
verify_key = "6C1D222D491FB88031E041A536CFB426101AA24B"

[dependencies.capa_uuid]
git = "https://github.com/nelsonduarte/capa_uuid"
tag = "v0.1.0"
verify_key = "6C1D222D491FB88031E041A536CFB426101AA24B"

[dependencies.capa_base64]
git = "https://github.com/nelsonduarte/capa_base64"
tag = "v0.1.0"
verify_key = "6C1D222D491FB88031E041A536CFB426101AA24B"
```

`capa install` runs the full three-layer supply-chain check on each:
the `capa.lock` commit SHA, the GPG tag signature (`git verify-tag`
against your keyring), and the SLSA L2 build provenance. It refuses to
install when a signature is absent, invalid, or from a different key.
The pinned commit SHAs are recorded in [`capa.lock`](./capa.lock).

## The capability posture is the security posture

The toolkit's guarantee is enforced by the compiler, not by convention.
`capa --manifest main.capa` proves the per-function capability surface:

- `verify_token` and `inspect_token` hold **zero capabilities**, so a
  token check provably cannot read a file, open a socket, read the clock,
  or spawn a process.
- `mint_token` holds **exactly `{Random, Clock}`** and nothing else.

[`leaky_verify.capa`](./leaky_verify.capa) is a counter-example that
tries to exfiltrate a token from inside verification without holding the
authority to do so: it constructs a `Net` locally with `Net()`. The
compiler rejects it, because a capability has no constructor and only
flows in through a function parameter (`capa --check leaky_verify.capa`):

```
leaky_verify.capa:56:15: error: capability 'Net' cannot be constructed at a call site; capabilities only flow through function parameters (declare net: Net on this function and let the caller pass it in). Constructing a capability locally would let any function silently obtain authority it never declared.
```

The only way to reach the network would be to *declare* `net: Net` as a
parameter, and then `capa --manifest` would report `leaky_verify` holding
`Net` in plain sight, on a function that is supposed to be pure. That is
what makes "verify is provably inert" a proof rather than a promise.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting channel:

  https://github.com/nelsonduarte/capa_authgate/security/advisories/new

Please include a reproducer if possible and allow up to 7 days for an
initial reply.
