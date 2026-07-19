# capa_authgate

A stateless **HS256 auth-token toolkit** with **two front-ends over one
pure verifier**: a CLI, and an HTTP service. It is a demonstration
**application**, not a library, and it exists to show three things about
Capa.

**1. Real composition.** It is built end to end from signed, pinned git
dependencies:

- [`capa_jwt`](https://github.com/nelsonduarte/capa_jwt) - HS256 sign /
  verify / expiry (itself pure, zero capabilities).
- [`capa_uuid`](https://github.com/nelsonduarte/capa_uuid) - a
  time-ordered v7 UUID for the token id (`jti`).
- [`capa_base64`](https://github.com/nelsonduarte/capa_base64) -
  base64url-decode a token's payload; base64-decode the supplied key.
- [`capa_server`](https://github.com/nelsonduarte/capa_server) - HTTP/1.1
  parsing and response writing for the service front-end. The HTTP is
  not hand-rolled here.

**2. Per-operation capability discipline, proven.** The token **verify**
path and the **inspect** path are **PURE**: they declare *zero*
capabilities, so the compiler proves a token check cannot read a file,
open a socket, read the clock, or spawn a process. Only **mint** holds
authority, and it holds **exactly `{Random, Clock}`**.

**3. The service does not weaken the claim, it sharpens it.** The
serving `main` holds **exactly `{Serve, Env, Clock}`**, and `Serve` is
**inbound-only** authority: `listen`, `accept`, `recv`, and `send` back
to a connection the runtime handed you. There is no method on it that
dials out. So the sentence the manifest supports is:

> the process holds the authority to **be reached**, and nothing else;
> and the function that touches your token holds nothing at all.

## The strongest fact in this repository

**`authgate.capa` needed ZERO changes to gain an HTTP front-end.**

```bash
$ git diff --stat -- authgate.capa
$                     # no output: not one byte
```

That is not luck. `verify_token(token, key, now_secs) -> Result<String,
AuthError>` was already the exact shape of a request handler, plain data
in and a `Result` out, **because the purity discipline had already
forced the caller to hold the `Clock` and pass `now` in as an `Int`**. A
verifier that read its own clock would have needed rewriting to be
served. This one is called the same way from `main.capa:98` (the CLI)
and from `service.capa`'s accept loop, and it holds nothing in either.

## The capability manifest (the point)

Generated from real `capa --manifest` output by
[`tools/manifest_table.py`](./tools/manifest_table.py), not written by
hand. Regenerate it with `python tools/manifest_table.py`.

| entry point | function | declared capabilities | notes |
| --- | --- | --- | --- |
| `service.capa` | `verify_token` | `[]` | PURE - the shared verifier, unchanged |
| `service.capa` | `inspect_token` | `[]` | PURE - unverified claims decode |
| `service.capa` | `handle` | `[]` | PURE - the whole HTTP request handler |
| `service.capa` | `verify_endpoint` | `[]` | PURE - `POST /verify` |
| `service.capa` | `inspect_endpoint` | `[]` | PURE - `POST /inspect` |
| `service.capa` | `token_from_body` | `[]` | PURE - reads attacker-supplied bytes |
| `service.capa` | `env_or` | `{Env}` | configuration, and only that |
| `service.capa` | `env_int` | `{Env}` | configuration, and only that |
| `service.capa` | `main` | `{Serve, Env, Clock}` | the SERVICE entry point, exactly this |
| `main.capa` | `mint_token` | `{Random, Clock}` | exactly, and nothing else |
| `main.capa` | `cmd_verify` | `{Stdio, Clock}` | the Clock is read here, not in the verifier |
| `main.capa` | `main` | `{Stdio, Env, Random, Clock}` | the CLI entry point |

`handle` is the whole HTTP request handler, routing and all, and it is
`[]`. Neither entry point ever acquires `Fs`, `Net`, `Db`, `Proc`, or
`Unsafe`, so "this service cannot read a file, dial out, or spawn a
process" is a machine-checked fact.

### The product ceiling

`capa.toml` declares one:

```toml
[capabilities]
max = ["Serve", "Env", "Clock", "Stdio", "Random"]
```

A ceiling is usually reached for by a *library*, to bound what a
consumer inherits. **It is worth at least as much to an application**,
because the application is the thing that actually gets deployed: this
is the machine-checked statement that neither entry point, and nothing
anywhere beneath either of them, introduces `Fs`, `Net`, `Db`, `Proc`,
or `Unsafe`. The set is the exact union of the two front-ends and no
more.

```bash
capa install
python tools/nest_vendor.py        # see "Building" below; needed once
capa --check-capabilities service.capa
capa --check-capabilities main.capa
```

```
capa: --check-capabilities: OK - every declared capability ceiling holds.
```

## The service

### Endpoints

| route | method | body | answers |
| --- | --- | --- | --- |
| `/verify` | `POST` | the token | `200` + verified claims, or `401` / `400` + an error code |
| `/inspect` | `POST` | the token | `200` + **unverified** claims, or `400` |
| `/` | `GET`, `HEAD` | - | a two-line index |

Anything else is `404`; a wrong method is `405` with an `Allow` header.

Both token endpoints are **`POST` with the token in the body**, not
`GET` with it in a query string. A token is a credential, and a query
string lands in access logs, proxy logs, browser history, and `Referer`
headers.

Rejections carry a **closed set of ASCII codes** (`bad_signature`,
`expired`, `unsupported_alg`, `malformed`, `bad_claim`, `server_key`)
and never `auth_error_message`, because three of the six `AuthError`
variants embed text taken from the token being checked. Nothing an
attacker sent is reflected back.

Status choice: a rejected credential is `401`, a token that never parsed
is `400` (the client sent nonsense, not a bad credential), and a key
*this server* could not decode is `500`, because that is the operator's
mistake rather than the client's.

### Running it

```bash
# the HMAC key, standard base64 (here, the bytes of "your-256-bit-secret")
export AUTHGATE_KEY=eW91ci0yNTYtYml0LXNlY3JldA==
export AUTHGATE_PORT=8137

capa --run service.capa
```

| variable | meaning |
| --- | --- |
| `AUTHGATE_KEY` | required. The HMAC key, standard base64. |
| `AUTHGATE_ADDR` | bind address, default `127.0.0.1` |
| `AUTHGATE_PORT` | bind port, default `8080` |
| `AUTHGATE_REQUESTS` | serve this many requests then stop; unset means until `accept` fails |

The `Env` is narrowed with `restrict_to_keys` to exactly those four
before the first read, and the `Serve` is narrowed with `restrict_to` to
exactly the one `(address, port)` **before** listening. The port is
always named explicitly and is never `0`: `Serve` checks the attenuation
against the **requested** port, so asking for port `0` would let a
`":0"` rule admit whatever ephemeral port the OS returned, including one
the same rule would refuse by number.

**The service prints nothing, deliberately.** Its surface is exactly
`{Serve, Env, Clock}`, and a log line would put a fourth capability in
the manifest, in plain sight. Startup failures use `panic`, whose
message reaches stderr without any capability:

```
$ capa --run service.capa
panic: authgate service: AUTHGATE_KEY is required (the HMAC key, standard base64)

$ AUTHGATE_KEY=notbase64!! capa --run service.capa
panic: authgate service: AUTHGATE_KEY is not valid standard base64
```

Those messages never quote a value read from the environment, only the
name of the variable.

### A session

Minted with the CLI, verified over HTTP, against a live server.

```bash
$ export AUTHGATE_KEY=eW91ci0yNTYtYml0LXNlY3JldA==
$ capa --run main.capa -- mint "$AUTHGATE_KEY" alice "read write" 3600 > token.txt
$ AUTHGATE_PORT=8137 capa --run service.capa &
```

```
$ curl -s -i -X POST --data-binary @token.txt http://127.0.0.1:8137/verify
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 141
Connection: close

{"valid":true,"claims":{"sub":"alice","scopes":"read write","iat":1784453120,"exp":1784456720,"jti":"019f79b1-c181-7a0e-b27a-3a167c6dc289"}}

$ curl -s -i -X POST --data-binary @tampered.txt http://127.0.0.1:8137/verify
HTTP/1.1 401 Unauthorized
Content-Type: application/json
Content-Length: 40
Connection: close

{"valid":false,"error":"bad_signature"}

$ curl -s -i -X POST --data-binary 'a.b' http://127.0.0.1:8137/verify
HTTP/1.1 400 Bad Request
Content-Type: application/json
Content-Length: 36
Connection: close

{"valid":false,"error":"malformed"}

$ curl -s -i -X POST --data-binary @token.txt http://127.0.0.1:8137/inspect
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 145
Connection: close

{"verified":false,"claims":{"sub":"alice","scopes":"read write","iat":1784453120,"exp":1784456720,"jti":"019f79b1-c181-7a0e-b27a-3a167c6dc289"}}

$ curl -s -i http://127.0.0.1:8137/verify
HTTP/1.1 405 Method Not Allowed
Content-Type: text/plain; charset=utf-8
Allow: POST
Content-Length: 23
Connection: close

405 Method Not Allowed
```

An expired token, minted with a negative TTL so its `exp` is in the
past:

```
HTTP/1.1 401 Unauthorized
Content-Type: application/json
Content-Length: 34
Connection: close

{"valid":false,"error":"expired"}
```

## What the service costs you, honestly

### 1. It loses `--wasm`

The CLI front-end still produces **byte-identical output on the Python
and Wasm backends**. The service does not, and cannot:

```
$ capa --wasm --run service.capa
capa: --wasm: the Serve capability is intentionally not supported on the Wasm
backend (binding a listening socket needs wasi:sockets, which is neither
vendored in capa/wasi_wit nor reachable from the wasmtime-py bindings the Wasm
hosts are built on, so a guest can never be handed an inbound connection). Use
the Python backend for these functions, or refactor to remove the Serve
parameter.
  - read_request(serve: Serve)
  - serve_once(serve: Serve)
  - serve_connections(serve: Serve)
  - main(serve: Serve)
```

That refusal is by design and permanent for now, not a backlog item.
So, precisely:

| runs on both backends | Python only |
| --- | --- |
| `authgate.capa`, `main.capa`, `example.capa`, `router.capa`, both test files | `service.capa` |

Note that `router.capa` is in the left column. Because the handler is
pure, `tests/test_service.capa` drives **every route** through
`parse_request` and `handle` on both backends and asserts byte-identical
output. Only the accept loop is Python-only.

### 2. Sequential, one connection at a time

`Serve` offers no threads, no async, and no concurrency, so neither does
this service. It accepts one connection, serves it, closes it, and
accepts the next. Do not read any throughput claim into it. Concurrency
is deliberately deferred rather than unfinished; the reasoning is in the
compiler's
[`docs/design/async-feasibility.md`](https://github.com/nelsonduarte/Capa_language/blob/main/docs/design/async-feasibility.md).

An idle server exits when `accept` hits the capability's 30-second
timeout. That is `Serve`'s shape, not a crash. Set `AUTHGATE_REQUESTS`
to bound a run explicitly.

### 3. The TCP reset caveat, which hits successful responses too

Closing a connection while bytes the client sent are still unread makes
the kernel send an RST instead of a FIN, and an RST discards data
already queued for transmission. **The response can be destroyed in
flight, on the success path, nondeterministically**, and the client sees
`ECONNRESET` rather than a status. Measured on loopback, 6 trials each:
32 bytes unread lost 0 responses, 64 KiB lost 4, 1 MiB lost 6.

`Serve` exposes no half-close, so no library can fix this, and
`capa_server` cannot either. Its README has the full scope and the
measurements under **Known limitations**; that is the authoritative
statement and this is a pointer to it, not a restatement. A client that
wants its response reliably should send exactly one request and nothing
more.

### 4. `Serve.send` is a public information-flow sink

On its payload argument. If a token or a key were labelled `@secret`,
sending it back would be reported by the analyzer. That is not
hypothetical here: the HMAC key comes from `env.get`, which **is** a
secret source, so the handler closure that captures it is labelled
`@secret` and the analyzer reports it reaching `serve_once`.

`service.capa` carries exactly one `declassify` about a secret, at that
one site, with the argument written out: no path in `handle` derives any
part of a `Response` from the key. Read the comment there, including
what it admits, which is that past that line the analysis no longer
guards the fact for you. Bind address and port are declassified
separately, for the different and much weaker reason that a bind address
is not a credential.

### 5. `recv` data is `@public`, which is about confidentiality only

The bytes of an inbound request are labelled `@public`. That is a
**confidentiality** statement: it says only "not a secret this analysis
must protect", so that echoing a request back to the client who sent it
is not flagged as a leak. It asserts **nothing** about the data being
trustworthy, well-formed, or safe to act on. An inbound request is
attacker-controlled. Capa's lattice does not model integrity or taint,
and this service validates every inbound byte on the assumption that it
is hostile.

## The counter-examples

Two files that deliberately do the wrong thing, neither imported by
anything. They fail in **two different ways**, which is the point.

### `leaky_verify.capa` - the compiler refuses

A copy of the verify path that tries to POST the token to an attacker
from *inside* verification, by constructing a `Net` it was never given.

```bash
capa --check leaky_verify.capa
```

```
leaky_verify.capa:61:15: error: capability 'Net' cannot be constructed at a call site; capabilities only flow through function parameters (declare net: Net on this function and let the caller pass it in). Constructing a capability locally would let any function silently obtain authority it never declared.
  61 |     let net = Net()
                     ^

leaky_verify.capa: 1 error
```

(Verbatim on capa 1.18.0; the wording is unchanged since 1.16.0.)

A capability has no constructor. The only way to reach the network would
be to *declare* `net: Net`, and then `capa --manifest` would report a
"pure" verifier holding `Net`, in plain sight.

### `leaky_handler.capa` - the compiler allows, the ceiling refuses

The service has a subtler route, and it is worth being exact about it.
`capa_server`'s handler type is `Fun(Request) -> Response`, so a handler
*cannot declare* a capability parameter. But a handler is a **closure**,
and Capa lets a closure capture a capability. So authority can ride into
a handler whose type says it is inert. `leaky_handler.capa` does exactly
that, and **it compiles**:

```bash
$ capa --check leaky_handler.capa
leaky_handler.capa:119:66: warning: information-flow: a @secret value is passed
to 'serve_once' as handler, which reaches a public sink inside 'serve_once' (it
sends data out of the program). ...

leaky_handler.capa: ok (198 items, 4259 expressions typed, 2137 bindings)
```

The information-flow warning it emits does **not** catch this: it
is the same warning `service.capa` gets for the innocent reason that its
handler captures the key, and one `declassify` would silence it. What
catches it is the ceiling, one level up:

```bash
$ capa --check-capabilities leaky_handler.capa
capa: --check-capabilities: FAILED - 1 ceiling violation(s):
  - package 'capa_authgate' declares max=['Clock', 'Env', 'Random', 'Serve', 'Stdio'] but its own code introduces 'Net'
```

while `capa --check-capabilities service.capa` reports `OK`, because the
gate composes from the entry point it is given. The authority could not
hide in the closure, because it could not get *into* the closure without
`main` declaring it, and `main`'s declaration is the package's
authority.

So: **a type-level guarantee** that a pure function cannot obtain
authority, and **a product-level gate** that refuses a program asking
for more than it promised. The second is the one that matters when the
leak is legal code.

## Building

**Requires a released `capa` 1.18.0 or newer**, which is what
`capa.toml` declares as `capa = ">=1.18.0"`. The compiler does not read
that field, so it is stated here too rather than left implicit. Two
things put the floor where it is: `Serve`, which `service.capa` needs,
shipped in 1.17.0; and 1.18.0 is the first release whose binaries carry
a SLSA provenance attestation, which the release guard verifies before
it builds this package with them. Every release of this repository is
gated on a clean-room build performed with exactly that floor version.

```bash
capa install                       # six runtime dependencies, plus capa_test
python tools/nest_vendor.py        # only needed for --check-capabilities
```

Two notes on `capa install`, both real and both worth knowing before you
copy this manifest:

**It does not resolve dependencies transitively.** It reads the *root*
`capa.toml` only and never opens a vendored package's manifest, so a
dependency's own dependencies are never fetched. `capa.toml` therefore
declares `capa_hash` (which `capa_jwt` needs) and `capa_url` (which
`capa_server` needs) directly, even though nothing here imports them,
with the pins copied from those packages' own lockfiles. Without them
the build fails on a clean checkout at `import capa_hash.hmac` inside
`vendor/capa_jwt/jwt.capa`. This was a **latent break in v0.1.0**: it
only appeared to work on a machine that happened to have a sibling
checkout of `capa_hash` next to this repository, which the module
resolver fell back to at the time. **capa 1.18.0 removed that
fallback**, so an undeclared transitive dependency now fails loudly
rather than silently resolving against unverified sources next door.
The entries were required either way; what changed is that forgetting
them can no longer look like success.

**The ceiling gate expects a nested vendor layout.** `capa install`
vendors flat (`vendor/<name>` for every package at any depth), while the
SBOM composition behind `--check-capabilities` looks for a dependency of
package P at `vendor/P/vendor/<name>`. Finding nothing, it fails closed,
correctly but on a layout question. `tools/nest_vendor.py` mirrors the
flat tree into the nested one, copying only packages `capa install`
already fetched, verified, and pinned. `vendor/` is gitignored, so this
is a build step and not a commit.

## The CLI

Keys are raw HMAC bytes supplied as **standard base64**.

```bash
KEY=eW91ci0yNTYtYml0LXNlY3JldA==

# mint <key_b64> <subject> <scopes> <ttl_secs>
TOKEN=$(capa --run main.capa -- mint "$KEY" alice "read write" 3600)

# verify <key_b64> <token>   (main reads `now`, verify_token stays pure)
capa --run main.capa -- verify "$KEY" "$TOKEN"

# inspect <token>            (decode claims WITHOUT verifying)
capa --run main.capa -- inspect "$TOKEN"
```

```bash
capa --run example.capa          # mint, verify, inspect, reject a tamper
capa --wasm --run example.capa   # byte-identical output
```

## API surface

From `authgate.capa`, unchanged:

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

From `router.capa`, the pure HTTP surface:

```capa
pub fun handle(r: Request, key: List<Int>, now_secs: Int) -> Response
```

- **`verify_token`** delegates the signature and algorithm-confusion
  checks to `capa_jwt.verify_hs256` (constant-time tag compare,
  `alg:"HS256"` required before any signature is trusted), then rejects
  the token with `Expired` when `exp <= now_secs`. **Pure.** `now_secs`
  is supplied by the caller, which is what keeps it capability-free.
- **`mint_token`** draws a v7 UUID (`jti`) with `capa_uuid`, reads the
  clock once for `iat`, and signs compact claims with
  `capa_jwt.sign_hs256`. **Declares exactly `{Random, Clock}`.**
- **`inspect_token`** base64url-decodes the payload segment and returns
  the claims JSON **without** verifying the signature (a debug / audit
  helper; the claims are UNTRUSTED). **Pure.**
- **`handle`** routes a parsed request to one of the above and returns a
  `Response`. **Pure**, which is why it can be tested without a socket.

## Verification

```bash
capa test          # Python backend
capa test --both   # Python + Wasm, byte-identical stdout required
```

```
capa test: 2 file(s) under .../capa_authgate/tests [backend: python+wasm]
test_authgate.capa ... ok
test_service.capa ... ok
2 test(s): 2 passed, 0 failed
```

`test_authgate.capa` covers the toolkit: mint then verify, a tampered
token (`BadSignature`), an expired token by passing a `now_secs` past
`exp` (`Expired`), `inspect` without verifying, and a minted `jti` that
is a valid UUID.

`test_service.capa` covers every HTTP route **without opening a port**.
That is not a testing convenience, it is the discipline paying out:
`handle` is pure, so a test builds request bytes, parses them with
`capa_server`'s real parser, calls the handler, and reads the response
value. Nothing is mocked, because there was no I/O to mock. It asserts
statuses, exact bodies, the `Allow` header on a 405, that a rejection
never echoes the token, that a percent-encoded `/%76erify` is **not**
routed as `/verify` (the router matches the raw target, un-normalised),
and that every response passes `check_response`.

## Honest posture

- **Verified, not audited.** The HS256 primitive comes from `capa_jwt`,
  checked against the jwt.io vector and Python's stdlib but **not**
  reviewed by a cryptographer. This toolkit adds no crypto of its own.
- **No TLS.** `Serve` is a plain TCP listener. Terminate TLS in front of
  it. The default bind is loopback for a reason.
- **No rate limiting, no authentication of the caller.** Anyone who can
  reach the port can ask it to check tokens. It is a demonstration.
- **A JWT is signed, not encrypted.** The payload is base64url, not
  secret; `inspect_token` reads it without any key.
- **`inspect_token` does not verify.** Its claims are UNTRUSTED by
  design, which the response body says in a field (`"verified":false`)
  rather than in a comment nobody reads.
- **The token id is not a secret.** `capa_uuid` uses a fast reproducible
  PRNG (SplitMix64), not a CSPRNG.
- **Key strength is the caller's job.** HS256 security rests on a
  high-entropy key of at least 32 bytes (RFC 7518 section 3.2).

## License

MIT. See [`LICENSE`](./LICENSE). Release tags are GPG-signed; see
[`SECURITY.md`](./SECURITY.md) for the fingerprint and verification
instructions.
