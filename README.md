# capa_authgate

A stateless **HS256 auth-token toolkit** and CLI: mint a signed JWT,
verify one, and inspect its claims. It is a demonstration **application**,
not a library, and it exists to show two things about Capa.

**1. Real composition.** It is built end to end from three seed
libraries, each a real, GPG-signed git dependency:

- [`capa_jwt`](https://github.com/nelsonduarte/capa_jwt) - HS256 sign /
  verify / expiry (itself pure, zero capabilities).
- [`capa_uuid`](https://github.com/nelsonduarte/capa_uuid) - a
  time-ordered v7 UUID for the token id (`jti`).
- [`capa_base64`](https://github.com/nelsonduarte/capa_base64) -
  base64url-decode a token's payload; base64-decode the supplied key.

**2. Per-operation capability discipline, proven.** The token **verify**
path and the **inspect** path are **PURE**: they declare *zero*
capabilities, so the compiler proves a token check cannot read a file,
open a socket, read the clock, or spawn a process. Only **mint** holds
authority, and it holds **exactly `{Random, Clock}`** (a random token id
plus the issue time), nothing more. `capa --manifest main.capa` prints
the per-function surface;
[`leaky_verify.capa`](./leaky_verify.capa) shows the compiler *rejecting*
a verify path that tries to exfiltrate the token without authority.

The verifier is pure because **the caller holds the `Clock` and passes
`now` in**. That single design choice (inherited from `capa_jwt`) is what
keeps verification provably inert. Output is byte-identical on the Python
and Wasm backends.

## The capability manifest (the point)

`capa --manifest main.capa` reports, per function:

| function        | declared capabilities        | notes                              |
| --------------- | ---------------------------- | ---------------------------------- |
| `verify_token`  | `[]`                         | PURE - provably cannot do any I/O  |
| `inspect_token` | `[]`                         | PURE - provably cannot do any I/O  |
| `mint_token`    | `{Random, Clock}`            | exactly, and nothing else          |
| `main`          | `{Env, Stdio, Random, Clock}`| the union of what the CLI delegates |

`main` draws the *exact* union of what it uses: `Env` + `Stdio` for the
CLI itself, and `Random` + `Clock`, which it only passes through to
`mint_token`. It never acquires `Fs`, `Net`, `Db`, `Proc`, or `Unsafe`,
so "this tool cannot read a file, open a socket, or reach a database" is
a machine-checked fact.

## API surface

From `authgate.capa`:

```capa
pub fun verify_token(token: String, key: List<Int>, now_secs: Int) -> Result<String, AuthError>
pub fun mint_token(rand: Random, clock: Clock, key: List<Int>, subject: String, scopes: String, ttl_secs: Int) -> String
pub fun inspect_token(token: String) -> Result<String, AuthError>

pub type AuthError =
    BadSignature             // HS256 tag does not match the key
    UnsupportedAlg(String)   // header `alg` was not HS256 (confusion defense)
    Expired                  // a valid token whose `exp` is at or before now
    Malformed(String)        // segment count, base64, JSON, or encoding
    BadClaim(String)         // a claim is absent or the wrong type
    BadKey(String)           // the supplied base64 key would not decode

pub fun auth_error_message(e: AuthError) -> String
```

- **`verify_token`** delegates the signature and algorithm-confusion
  checks to `capa_jwt.verify_hs256` (constant-time tag compare,
  `alg:"HS256"` required before any signature is trusted), then rejects
  the token with `Expired` when `exp <= now_secs`. **Pure.** `now_secs`
  is supplied by the caller, which is what keeps it capability-free.
- **`mint_token`** draws a v7 UUID (`jti`) with `capa_uuid`, reads the
  clock once for `iat`, and signs compact claims
  `{"sub":...,"scopes":...,"iat":now,"exp":now+ttl,"jti":...}` with
  `capa_jwt.sign_hs256`. **Declares exactly `{Random, Clock}`.**
- **`inspect_token`** base64url-decodes the payload segment via
  `capa_base64` and returns the claims JSON **without** verifying the
  signature (a debug / audit helper; the claims are UNTRUSTED). **Pure.**

## Quick start

```bash
capa install                     # vendor capa_jwt + capa_uuid + capa_base64
capa --run example.capa          # mint, verify, inspect, reject a tamper
capa --wasm --run example.capa   # byte-identical output
```

### CLI

Keys are raw HMAC bytes supplied as **standard base64**.

```bash
# a base64 key (here, the bytes of "your-256-bit-secret")
KEY=eW91ci0yNTYtYml0LXNlY3JldA==

# mint <key_b64> <subject> <scopes> <ttl_secs>
TOKEN=$(capa --run main.capa -- mint "$KEY" alice "read write" 3600)

# verify <key_b64> <token>   (main reads `now`, verify_token stays pure)
capa --run main.capa -- verify "$KEY" "$TOKEN"

# inspect <token>            (decode claims WITHOUT verifying)
capa --run main.capa -- inspect "$TOKEN"
```

## The counter-example

[`leaky_verify.capa`](./leaky_verify.capa) is a copy of the verify path
that tries to POST the token to an attacker from *inside* verification, by
constructing a `Net` it was never given. It is never imported by the
toolkit. Run:

```bash
capa --check leaky_verify.capa
```

```
leaky_verify.capa:56:15: error: capability 'Net' cannot be constructed at a call site; capabilities only flow through function parameters (declare net: Net on this function and let the caller pass it in). Constructing a capability locally would let any function silently obtain authority it never declared.
  56 |     let net = Net()
                     ^

leaky_verify.capa: 1 error
```

A capability has no constructor: `Net()` cannot forge authority, and a
pure verifier holds no `Net`, so the program does not compile. **You
cannot leak silently:** the only way to reach the network would be to
*declare* `net: Net` as a parameter, and then `capa --manifest` would
report `leaky_verify` holding `Net`, in plain sight, on a function that is
supposed to be pure. The leak moves out of the code and into the
auditable capability manifest, where any reviewer or a CI capability-diff
gate sees it. The empty surface is a **proof**, not a promise.

## Verification

```bash
capa test          # Python backend
capa test --both   # Python + Wasm, byte-identical stdout required
```

The suite mints a token then verifies it (Ok, claims returned), rejects a
tampered token (`BadSignature`), rejects an expired token by passing a
`now_secs` past `exp` (`Expired`), decodes claims with `inspect` without
verifying, and checks that a minted `jti` is a valid UUID (via
`capa_uuid.is_valid`). The exact-outcome cases use the pure
`capa_jwt.sign_hs256` to build fixed tokens, so their bytes are
deterministic and identical on both backends; the live `mint_token`
round-trip asserts only backend-stable structural properties (it carries
a wall-clock time and a random `jti`).

Current output of `capa test --both`:

```
capa test: 1 file(s) under .../capa_authgate/tests [backend: python+wasm]
test_authgate.capa ... ok
1 test(s): 1 passed, 0 failed
```

## Honest posture

- **Verified, not audited.** The HS256 primitive comes from `capa_jwt`,
  which is checked against the jwt.io vector and Python's stdlib but has
  **not** been reviewed by a cryptographer. This toolkit adds no crypto
  of its own; it composes and gates.
- **A JWT is signed, not encrypted.** The payload is base64url, not
  secret. Do not put confidential data in a token and expect it hidden;
  `inspect_token` reads it without any key.
- **`inspect_token` does not verify.** Its claims are UNTRUSTED by
  design (a debug / audit view). Always `verify_token` before trusting a
  claim.
- **The token id is not a secret.** `capa_uuid` uses a fast reproducible
  PRNG (SplitMix64), not a CSPRNG. The `jti` is fine as an identifier but
  must not be relied on for unpredictability.
- **Key strength is the caller's job.** HS256 security rests on a
  high-entropy key of at least 32 bytes (RFC 7518 section 3.2). This tool
  does not generate keys; supply a strong one you manage yourself.

## License

MIT. See [`LICENSE`](./LICENSE). Release tags are GPG-signed; see
[`SECURITY.md`](./SECURITY.md) for the fingerprint and verification
instructions.
