# Phase 22-3: HTTP Listener + Router + TLS Verify Block

> Depends on: `phase22-0-overview.md`, `phase22-1-pairing-code.md`,
> `phase22-2-identity-trust.md` (needs `ServerIdentity` for the TLS local
> identity and `TrustedDevices` for the verify block).
>
> Binding docs: `_standards.md`, `sync-protocol.md` sections 3, 5, 6.

## Goal

The transport backbone: an `NWListener` with mutual TLS whose verify block
enforces the pairing-mode-vs-trusted rule, a hand-rolled HTTP/1.1 parser with
hard safety caps, a `Router` that dispatches the nine endpoints, and the one
always-available endpoint `GET /v1/ping`. Everything above this (pairing,
manifest, files) plugs into the `Router` in later slices. This slice proves the
listener over loopback with a real `URLSession`.

This is deliberately the "dumb pipe" slice: no library reads, no pairing state,
no file serving. Get the socket, TLS, parser, and routing skeleton correct and
tested in isolation.

## Outcome shape

```
Modules/SyncServer/Sources/SyncServer/
  Http/HttpConnection.swift     // one NWConnection: parse request, write response
  Http/HttpRequest.swift        // parsed method + path + query + headers + body
  Http/HttpResponse.swift       // status + headers + body, plus helpers
  Http/Router.swift             // path/method table -> handler; 404/405/411
  Transport/TLSOptions.swift    // NWProtocolTLS.Options from ServerIdentity + verify block
  Transport/ConnectionContext.swift // per-connection: peer cert DER + fingerprint, pairing flag
Modules/SyncServer/Tests/SyncServerTests/
  HttpParserTests.swift
  RouterTests.swift
  LoopbackTLSTests.swift
```

## HTTP constraints (deliberate, sync-protocol.md section 5)

A hand-rolled server is only safe if it is boring. Enforce:

- **HTTP/1.1 only.** Parse the request line (`METHOD SP path SP HTTP/1.1`).
- **Content-Length required on bodies; chunked transfer encoding rejected with
  `411 Length Required`.** No chunked in either direction.
- **Caps**: request line + headers together capped at **16 KB**; body capped at
  **1 MB** (bodies are only small pairing JSON). Exceeding either is a hard
  reject (`431`/`413` respectively, or close). Read the header block first, parse
  `Content-Length`, then read exactly that many body bytes.
- **Sequential keep-alive** is supported (read next request after writing a
  response) but there is no pipelining requirement; **close on any parse error**.
- **Responses always carry `Content-Length`.** No chunked responses. (Gzip for
  the manifest is added in phase 22-5 and still sets `Content-Length` on the
  compressed body.)
- Unknown method -> `405`; unknown path -> `404`; malformed -> `400` then close.
- Errors use the protocol envelope: `{ "error": "<machineCode>", "message":
  "<human text>" }` with codes from section 5 (`notPaired`, `pairingExpired`,
  `badProof`, `rateLimited`, `notFound`, `busy`, `internal`).

The parser is the security surface. It never allocates unbounded buffers, never
trusts `Content-Length` beyond the cap, and treats the path as opaque (no file
paths here; see phase 22-6). Property-test it with truncated, oversized, and
malformed inputs.

## TLS options and the verify block (sync-protocol.md section 3)

`TLSOptions.make(identity:trust:pairingMode:)` returns `NWProtocolTLS.Options`:

- Set the **local identity** from `ServerIdentity.secIdentity` via
  `sec_protocol_options_set_local_identity`.
- Force **TLS 1.3** minimum (`sec_protocol_options_set_min_tls_protocol_version`;
  fall back to 1.2 only if the stack refuses, and `log.warning`).
- **Request a client certificate**
  (`sec_protocol_options_set_peer_authentication_required(true)`).
- Install a **verify block**
  (`sec_protocol_options_set_verify_block`) that:
  1. Extracts the peer (client) certificate DER from the
     `sec_protocol_metadata` / `sec_trust`, computes its SHA-256 fingerprint.
  2. Records `{certDER, fingerprint}` onto the `ConnectionContext` for this
     connection (the ceremony and the trusted check both read it).
  3. If `pairingMode` is on: **accept** (verify_complete `true`), tag the
     connection `isPairing = true`.
  4. If `pairingMode` is off: accept **only if** the fingerprint is in
     `TrustedDevices` (async lookup), else reject (`false`). This is where
     revocation bites on the next connection.

`pairingMode` and the trusted set are read from the owning `SyncServer` actor
(passed in as a small `Sendable` accessor closure so `TLSOptions` does not import
the actor). Keep the verify block's async work minimal and off the MainActor.

> Note: the verify block runs per-handshake. The trusted-set lookup should hit an
> in-memory snapshot the `SyncServer` refreshes from `TrustedDevices` on change,
> not a fresh DB round-trip per handshake, to keep handshakes cheap. Phase 22-2
> provides the snapshot; this slice consumes it.

## Router and `/v1/ping`

`Router` maps `(method, pathTemplate)` to a handler closure. Path templates use a
tiny matcher for the `{id}` segments (`/v1/file/track/{trackId}` etc.); no regex,
just split-on-`/` with typed captures. The full table (auth column enforced in
later slices via the `ConnectionContext.isPaired` flag):

| Method | Path | Slice that adds the handler |
|--------|------|-----------------------------|
| GET | `/v1/ping` | this slice |
| POST | `/v1/pair/start` | 22-4 |
| POST | `/v1/pair/confirm` | 22-4 |
| GET | `/v1/manifest` | 22-5 |
| GET | `/v1/file/track/{trackId}` | 22-6 |
| GET | `/v1/file/episode/{episodeId}` | 22-6 |
| GET | `/v1/artwork/{hash}` | 22-6 |
| GET | `/v1/lyrics/{trackId}` | 22-6 |
| GET | `/v1/chapters/{episodeId}` | 22-6 |

`GET /v1/ping` is the only endpoint available to any successfully-handshaked TLS
peer (pairing or paired). It returns `{ protocolVersion, serverId, generation }`.
In this slice `serverId`/`generation` can be injected constants (a
`PingProviding` closure) since `sync_meta` wiring lands in 22-5; keep the handler
thin and inject its data.

Authorization model (implemented incrementally): a request is `paired` if its
connection's client-cert fingerprint is in `TrustedDevices`. `/v1/ping` and the
two `/v1/pair/*` endpoints are allowed pre-pairing; every other endpoint returns
`403 notPaired` unless the connection is paired. The `Router` reads
`ConnectionContext.isPaired` (set during the verify block) rather than
re-checking per request.

## Tests

- **`HttpParserTests`**: well-formed GET and POST-with-body; missing
  `Content-Length` on a body -> handled; chunked `Transfer-Encoding` -> `411`;
  16 KB+ header block -> rejected; 1 MB+ body -> rejected; split-across-reads
  input reassembles correctly; garbage first line -> `400` + close. Property test
  over random truncations never crashes or hangs.
- **`RouterTests`**: known path/method -> handler invoked; unknown path -> `404`;
  known path wrong method -> `405`; `{id}` capture parses; a non-paired
  connection hitting a paired-only path -> `403 notPaired`.
- **`LoopbackTLSTests`**: start the listener on `127.0.0.1:0`, read the bound
  port, drive it with a `URLSession` whose delegate trusts the test server cert
  and presents a test client cert. Assert:
  - `GET /v1/ping` returns 200 + the ping JSON when pairingMode is on.
  - With pairingMode off and an untrusted client cert, the handshake is refused
    (connection fails at TLS, not a 403).
  - With pairingMode off and a trusted client cert (seed `TrustedDevices`), ping
    succeeds.
  - Handlers run off the MainActor (assert the executor is the server actor's,
    not `MainActor`).

Generating a throwaway P-256 identity + client cert for the loopback test is
shared helper code with phase 22-2's tests; factor it into a `TestIdentity`
helper under `Tests/`.

## Context7 lookups

- use context7: Network.framework NWListener NWConnection NWProtocolTLS.Options
  sec_protocol_options_set_verify_block sec_protocol_metadata peer certificate
- use context7: URLSession URLSessionDelegate client certificate challenge
  serverTrust test self-signed

## Acceptance criteria

- [ ] Parser enforces every cap in section 5; chunked -> `411`; oversized ->
      rejected; property test green.
- [ ] `Router` returns correct `404`/`405`/`403` and dispatches `{id}` paths.
- [ ] Loopback TLS: ping succeeds in pairing mode; untrusted client refused at
      TLS when not pairing; trusted client succeeds.
- [ ] Verify block records peer cert + fingerprint on the connection and gates on
      `TrustedDevices` outside pairing mode.
- [ ] Handlers proven to run off the MainActor.
- [ ] `make format && make lint && make build && make test-sync-server` green;
      coverage floor met.

## Handoff

Phase 22-4 registers `/v1/pair/*` on this `Router` and reads the recorded peer
cert from `ConnectionContext`. Phases 22-5 and 22-6 register the paired-only
endpoints. Phase 22-7 owns the `SyncServer` actor that constructs the listener
with these `TLSOptions` and flips `pairingMode`.
