# Vendored dependency patches

## `courierust` (TLS/HTTP engine)

* Upstream: `courierust 1.0.9` (crates.io), `blueokanna/Courierust`, MIT/Apache-style license kept in `courierust/LICENSE`.
* Wired in through `[patch.crates-io]` in `rust/Cargo.toml`; only `src/`, `proto/`, `build.rs`, `Cargo.toml`, `LICENSE` and the upstream `README.md` are vendored.

### Deviation 1: extended master secret (RFC 7627)

`src/courierust_tls/tls12.rs`, client handshake:

* The fingerprint profiles advertise `extended_master_secret` (`0x0017`), but the TLS 1.2 key schedule always derived the classic master secret. A server that honours the offer derives over the session hash instead, so the two sides compute different keys and the server answers the client `Finished` with a fatal `bad_record_mac` — which is exactly what Bilibili's `upos-sz-mirrorcos*.bilivideo.com` CDN edges did (OpenSSL/Go/rustls interoperate because they all implement the extension).
* The client now records the server's `extended_master_secret` echo while parsing the `ServerHello` and derives the master secret over the session hash — every handshake message up to and including the `ClientKeyExchange` — whenever it is present (RFC 7627 §4). The server side of the crate never echoes the extension, so it keeps the classic derivation and a client offering it falls back to classic as well (RFC 7627 §5.2).
* The session hash is the same transcript hash that authenticates the client `Finished`, so it is computed once and reused.

### Deviation 2: RFC 5077 ticket before the server `ChangeCipherSpec`

`src/courierust_tls/tls12.rs`, handshake completion:

* Upstream read exactly one record after sending the client `Finished` and failed with `expected server ChangeCipherSpec` when that record was anything else. Those CDN edges deliver a ~230-byte `NewSessionTicket` just before their `ChangeCipherSpec`, which OpenSSL, Go and rustls all accept.
* The client now reads records until the `ChangeCipherSpec` arrives, accepts `NewSessionTicket` handshake messages in front of it, and folds them into the transcript that authenticates the server `Finished` (RFC 5246 §7.4.9), in wire order — i.e. after the client `Finished`. Verified against the live edge, which rejects a wrong transcript.
* Remaining record types (alerts, surprises) are reported with their record type, and alerts with their level/description, instead of the previous generic message.

Nothing else in the crate is modified; every other TLS 1.2/1.3, HTTP/1.1-3, WebSocket and gRPC code path is upstream byte-for-byte. When upgrading `courierust`, re-apply these hunks (both are marked with a comment in the file) or drop the patch once upstream accepts them.

### Deviation 3: `#[allow(deprecated)]` on the three `fetch_update` sites

`src/courierust_h3/runtime.rs` (`H3Conn::release`), `src/courierust_client/h2.rs` (`H2Conn::release`) and `src/courierust_net/stats.rs` (`Stats::decrement`):

* Rust 1.99 renamed `AtomicUsize::fetch_update` to `try_update` and deprecated the old name. `try_update` is still an unstable feature on the workspace MSRV (1.88) — verified with that toolchain, `error[E0658]: use of unstable library feature 'atomic_try_update'` — so the pre-rename name is the only portable choice and the deprecation warning is silenced at those three functions.
* The method is not interchangeable behaviourally either: `fetch_update` retries its compare-and-swap internally, while `try_update` can return `Err` when it loses the race. These three sites maintain counters (H3 reservations, H2 reservations and body load, live-count metrics) that must not be dropped, which is the same reason the upstream author chose `fetch_update`.
* When the MSRV moves past the release that stabilises `try_update`, switch the three sites and delete this note.
