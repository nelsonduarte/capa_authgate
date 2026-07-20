# Security

`capa_authgate` is a demonstration application, not a cryptographic
library. It composes `capa_jwt` (HS256), `capa_uuid`, `capa_base64`, and
`capa_server` (HTTP/1.1), each **verified, not audited** (see each
library's own SECURITY.md). Read the [Honest
posture](./README.md#honest-posture) in the README before relying on it
for anything security-critical.

The HTTP front-end in `service.capa` adds exposure the CLI does not
have, and the README says so in full under "What the service costs you,
honestly". In summary: **no TLS** (`Serve` is a plain TCP listener;
terminate TLS in front, and the default bind is loopback), **no rate
limiting and no authentication of the caller**, **sequential** service
of one connection at a time, and a **TCP reset caveat** that can destroy
a response in flight, on the success path, whenever the client sent more
bytes than the server read. That last one is a property of `Serve`
having no half-close and is documented in full in `capa_server`'s
README.

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
git verify-tag v0.2.4
# Look for: "Good signature from "Nelson Duarte <...>" [ultimate]"
# and the fingerprint above.
```

## The dependency supply chain

`capa_authgate` pins **six** runtime dependencies by tag and
`verify_key` in [`capa.toml`](./capa.toml): `capa_jwt`, `capa_uuid`,
`capa_base64`, and `capa_server`, which it imports directly, plus
`capa_hash` and `capa_url`, which it does not.

Those last two are there because `capa install` reads the *root*
manifest only and never resolves a dependency's own dependencies.
`capa_hash` is `capa_jwt`'s and `capa_url` is `capa_server`'s; without
explicit entries neither is ever fetched, and a clean checkout fails to
build. Their pins are copied from the lockfiles of the packages that
depend on them, so the supply-chain check applies to them on exactly the
same terms as the rest, rather than their being resolved by accident
from whatever happened to sit next to the repository on disk. That
accident is what v0.1.0 relied on for `capa_hash`, and capa 1.18.0
removed the resolver fallback that made it possible. This package's
floor is 1.18.1, so no compiler it declares support for still has it.

`capa install` runs the full three-layer supply-chain check on each:
the `capa.lock` commit SHA, the GPG tag signature (`git verify-tag`
against your keyring), and the SLSA L2 build provenance. It refuses to
install when a signature is absent, invalid, or from a different key.
The pinned commit SHAs are recorded in [`capa.lock`](./capa.lock).

The SLSA layer needs the `gh` CLI. Because every dependency here
declares a `verify_key`, capa 1.18.1 and later **refuse** the install
when `gh` is absent rather than warning once per dependency and
continuing; `CAPA_ALLOW_MISSING_GH=1` is the escape and names every
dependency it lets through. Note what that does and does not cover: a
missing verifier is now fail-closed, but an `gh` that is present and
merely unauthenticated still degrades to a warning, because that path
is governed by `verify_provenance` (default `warn`). If you need the
provenance layer to be mandatory, set `CAPA_REQUIRE_PROVENANCE=1`.

## The capability posture is the security posture

The toolkit's guarantee is enforced by the compiler, not by convention.
`capa --manifest main.capa` and `capa --manifest service.capa` prove the
per-function capability surface:

- `verify_token` and `inspect_token` hold **zero capabilities**, so a
  token check provably cannot read a file, open a socket, read the clock,
  or spawn a process.
- `mint_token` holds **exactly `{Random, Clock}`** and nothing else.
- `handle`, the HTTP request handler in `router.capa`, holds **zero
  capabilities**. The piece of the service that touches
  attacker-supplied bytes and your token cannot reach the `Serve` that
  is about to transmit its answer.
- the serving `main` holds **exactly `{Serve, Env, Clock}`**, and
  `Serve` is inbound-only: it has no method that dials out.

The package additionally declares a ceiling, `max = ["Serve", "Env",
"Clock", "Stdio", "Random"]`, which `capa --check-capabilities` verifies
across both entry points and the whole dependency tree. `Fs`, `Net`,
`Db`, `Proc`, and `Unsafe` are therefore proven absent from the product,
not merely unused in the code you happened to read.

[`leaky_verify.capa`](./leaky_verify.capa) is a counter-example that
tries to exfiltrate a token from inside verification without holding the
authority to do so: it constructs a `Net` locally with `Net()`. The
compiler rejects it, because a capability has no constructor and only
flows in through a function parameter (`capa --check leaky_verify.capa`):

```
leaky_verify.capa:61:15: error: capability 'Net' cannot be constructed at a call site; capabilities only flow through function parameters (declare net: Net on this function and let the caller pass it in). Constructing a capability locally would let any function silently obtain authority it never declared.
```

The only way to reach the network would be to *declare* `net: Net` as a
parameter, and then `capa --manifest` would report `leaky_verify` holding
`Net` in plain sight, on a function that is supposed to be pure. That is
what makes "verify is provably inert" a proof rather than a promise.

[`leaky_handler.capa`](./leaky_handler.capa) is the companion
counter-example for the service, and it fails differently. A request
handler is a closure, and Capa lets a closure capture a capability, so
authority can ride into a handler whose type (`Fun(Request) ->
Response`) says it is inert. That file **compiles**. What refuses it is
the ceiling, when the ceiling is handed that file by name:

```
capa: --check-capabilities: FAILED - 1 ceiling violation(s):
  - package 'capa_authgate' declares max=['Clock', 'Env', 'Random', 'Serve', 'Stdio'] but its own code introduces 'Net'
```

The authority could not get into the closure without `main` declaring
it, and `main`'s declaration is the package's authority. Do not read the
information-flow warning that file also emits as the check that caught
it; that warning fires on `service.capa` too, for the innocent reason
that its handler captures the HMAC key.

**What the ceiling covers, exactly.** `capa --check-capabilities
<entry>` covers the import closure of the entry it is given, not the
package: a module that is not an entry point and is not imported by one
is never opened, and the command exits 0 having never seen it. Nothing
imports either `leaky_*` file, so both were invisible to a release that
checked `main.capa` and `service.capa` alone, and both claims above were
documentation rather than evidence. The release now names all five real
modules and runs the two counter-examples as negatives that must fail
with the message quoted above; `tests/test_release_wiring.sh` reads the
top-level `*.capa` files off disk and fails if the flow does not account
for every one of them.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting channel:

  https://github.com/nelsonduarte/capa_authgate/security/advisories/new

Please include a reproducer if possible and allow up to 7 days for an
initial reply.
