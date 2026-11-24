# MoonKeeper

[简体中文](README.md) | **English**

**A native Apache ZooKeeper client for MoonBit, under active development.**

MoonKeeper aims to let MoonBit applications connect directly to ZooKeeper for znode operations, configuration watches, service registration, and session management. The protocol and client logic are implemented in MoonBit.

## Current status

The protocol prototype and native TCP handshake are implemented. MoonKeeper can establish a new session with a real ZooKeeper 3.9.3 server.

Implemented so far:

- Encoding a `ConnectRequest` for a new session, including the four-byte big-endian length prefix.
- Decoding a complete `ConnectResponse` frame while preserving the 64-bit session ID, timeout, password, and read-only flag.
- Distinguishing an empty password from null and accepting legacy responses that omit `readOnly`.
- Checking for truncation, negative lengths, oversized frames, invalid field lengths, and trailing bytes.
- Incremental framing for fragmented and concatenated input, validating lengths before buffering payloads and detecting incomplete frames at EOF.
- Single-address native TCP, a combined connection/handshake deadline, negotiation validation, and connection cleanup on normal exit, errors, or cancellation.
- 25 portable protocol tests, 12 local TCP/client tests, and explicitly enabled real ZooKeeper integration tests.

**Connection establishment, the handshake, and serial `exists` queries are implemented.** Concurrent dispatch, heartbeats, node writes, watches, authentication, transactions, and session recovery remain planned. Leaving the scope closes TCP but does not yet send `closeSession`; the server expires the session after its negotiated timeout. Keeping the callback alive does not maintain the session automatically. The project has not been published to Mooncakes.

## Running locally

Development baseline: `moonc v0.10.19+bee578715` / `moon 0.1.20261102`. Native networking uses `moonbitlang/async@0.20.3` and requires a C toolchain; the protocol root package still uses only the standard library. Run from the project root:

```sh
moon update
moon check --deny-warn
moon test --deny-warn
moon run cmd/main
```

The example generates a 49-byte new-session request and then parses a fixed sample response. The session information in its output comes from that fixture. It does not connect to a server or print the session password.

The default backend is native. With ZooKeeper running, try the real connection example:

```sh
moon run cmd/connect --target native -- 127.0.0.1 2181
```

It prints the real session ID, negotiated timeout, and read-only flag, then closes the connection. Failures return a nonzero exit code. The default endpoint is `127.0.0.1:2181`; `--help` prints usage.

To check all backends (native requires a C toolchain; JS requires Node.js):

```sh
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
```

The protocol root package is tested on native, JS, wasm, and wasm-gc. The `client`, `cmd/connect`, and `integration` packages declare `supported_targets = "native"`; networking on other backends is not claimed.

## Real-server integration tests

Docker mode pins `zookeeper:3.9.3`, binds its port to loopback, stores data in temporary filesystems, and removes its own Compose project on exit. It requires a running Docker Engine and Compose v2 with `--wait` support:

```powershell
./scripts/integration.ps1 -Mode single
```

```sh
bash scripts/integration.sh single
```

Without Docker, start ZooKeeper separately and use existing-server mode, which leaves that server running:

```powershell
./scripts/integration.ps1 -Mode existing -HostName 127.0.0.1 -Port 2181
```

```sh
bash scripts/integration.sh existing 127.0.0.1 2181
```

Both scripts use a real protocol handshake for readiness before running integration tests. Missing dependencies, unavailable servers, and failed tests return nonzero. Regular `moon test` does not enable the real-server test marked `#skip`. To enable it manually, set `MOONKEEPER_ZK_PORT` (`MOONKEEPER_ZK_HOST` defaults to `127.0.0.1`) and run `moon test integration --target native --include-skipped --deny-warn`.

Validation: Windows native has passed handshake and repeated new-session tests using Java 17 and the official ZooKeeper 3.9.3 distribution verified by SHA512. Both PowerShell and Git Bash existing-server runners have been exercised. Linux native and Docker are checked by the [Native handshake workflow](https://github.com/backaccouup/MoonKeeper/actions/workflows/native-handshake.yml); consult its actual run results. macOS has not been verified.

## Current API

### Native client

Import `"Mr-Shi123/moonkeeper/client"` and `"moonbitlang/async"` in a native package, set `supported_targets = "native"`, and call from an async function:

```moonbit
let options = @client.ClientOptions::new(
  @client.Endpoint::new("127.0.0.1", port=2181),
  session_timeout_ms=30000,
  request_timeout_ms=10000,
)
@client.with_client(options, client => {
  let info = client.session_info()
  println(info.session_id)
  let root = client.exists("/")
  println(root)
})
```

`with_client[T]` returns the callback's result, propagates callback errors and cancellation unchanged, and closes TCP on every exit path. `SessionInfo` contains only `session_id`, `session_timeout_ms`, and `read_only`, never a password.

| Option | Default | Current purpose |
| --- | --- | --- |
| `session_timeout_ms` | 30000 | Requested session timeout; the server negotiates the actual value |
| `request_timeout_ms` | 10000 | Combined connection/handshake deadline; does not limit the callback |
| `max_frame_size` | 1048576 | Payload byte limit; the client accepts 45–1048576 |
| `read_only` | false | Allow a read-only server |
| `max_pending_requests` | 256 | Reserved for request dispatch; no application request queue exists yet |
| `event_buffer_capacity` | 256 | Reserved for notifications; no event queue exists yet |

`Client::exists(path)` returns `Stat?`. Only the server's `NoNode` becomes `None`; other server errors are raised. `Client::state()` exposes the state; `Client::close()` is idempotent and closes TCP. Requests are currently serialized by a mutex and use increasing positive xids. A read timeout closes this connection and marks it `Disconnected`, which does not prove that the ZooKeeper session expired. See [failure and lifecycle semantics](docs/semantics.md).

`ClientError` distinguishes invalid options, transport failures, handshake or request timeouts, protocol and server errors, session rejection, and closed state. The client validates the protocol version, negotiated timeout, nonzero session ID, 16-byte password, and read-only permission. Errors contain neither raw responses nor passwords. The module namespace remains `Mr-Shi123/moonkeeper` and is managed separately from the GitHub commit identity.

### Portable protocol

Import `"Mr-Shi123/moonkeeper"` in a consuming package within the same module, then use:

```moonbit
let request = @moonkeeper.encode_connect_request(30000)
// This low-level function only produces bytes; use the client package for networking.
```

`encode_connect_request` only creates requests for new sessions: the protocol version, last zxid, and session ID are all zero, and the password is 16 zero bytes. The timeout must be positive. Set `read_only=true` to allow a connection to a read-only server.

`decode_connect_response` accepts **one complete frame**, including its length prefix. It neither buffers fragments nor splits concatenated frames. The payload limit is 1 MiB, a local limit imposed by this library rather than a universal ZooKeeper protocol limit.

Successful decoding only means that the byte structure is valid; it does not mean that a session has been established. The `client` package validates the protocol version, negotiated timeout, and password fields. For example, a rejection response with a timeout of zero can still be decoded by the low-level codec. Session passwords are credentials and should not be logged.

For streaming input, create `FrameDecoder::new(max_frame_size=1048576)`, call `feed(Bytes)` to obtain complete frames including their four-byte headers, and call `finish()` to detect a partial frame. A clean `finish()` is idempotent; calling `feed` after finishing or encountering an error fails.

## Project structure

```text
handshake.mbt         Handshake encoding, decoding, and error types
handshake_test.mbt    Independent fixtures and error boundary tests
frame.mbt             Incremental framing; frame_test.mbt contains its tests
client/               Native connection scope, transport, errors, and local TCP tests
pkg.generated.mbti   Public interface generated by moon info
cmd/main/            Offline example
cmd/connect/         Real-server connection example
integration/         ZooKeeper 3.9.3 environment and real-server tests
scripts/             PowerShell / Bash integration runners
```

## Roadmap

Ten feature increments extend the original protocol prototype. Documentation maintenance is tracked separately, so feature stages do not equal the total number of Git commits.

| Stage | Scope | Status |
| --- | --- | --- |
| 1 | Project setup, handshake codec, tests, and offline example | Implemented |
| 2 | Native TCP, incremental framing, and handshake with a real server | Implemented |
| 3 | Request IDs, response dispatch, heartbeats, and timeouts | In progress: serial exists and request timeout |
| 4 | Create, read, update, and delete znodes | Planned |
| 5 | Children, stat metadata, version checks, and ephemeral/sequential nodes | Planned |
| 6 | Watch registration, notification dispatch, and cancellation semantics | Planned |
| 7 | ACLs and Digest authentication | Planned |
| 8 | Atomic `multi` operations and structured server errors | Planned |
| 9 | Reconnection across multiple addresses, session recovery, and failure semantics | Planned |
| 10 | CLI, configuration watch, and service registration examples | Planned |
| 11 | Full cluster fault/interoperability checks and delivery documentation | Planned |

## Protocol references and license

MoonKeeper is an independent implementation based on Apache ZooKeeper's public protocol definitions. It does not wrap or copy another language's client implementation. The current handshake fields follow **ZooKeeper 3.9.3**:

- [zookeeper.jute](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/resources/zookeeper.jute): field order and types.
- [BinaryInputArchive.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/java/org/apache/jute/BinaryInputArchive.java): Jute integer, buffer, and boolean semantics.
- [ProtocolManager.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-server/src/main/java/org/apache/zookeeper/compat/ProtocolManager.java): the optional read-only field used for compatibility with older clients and servers.

Fixed fixtures were constructed manually from these definitions, not captured from a live service. Real-server handshakes are validated separately by integration tests; independent-client and cluster validation remain planned. Native async I/O uses the Apache-2.0-licensed `moonbitlang/async` library.

Apache-2.0; see [LICENSE](LICENSE). Copyright 2026 Mr-Shi123; new code Copyright 2026 backaccouup. MoonKeeper is an independent community project and is not affiliated with the Apache ZooKeeper project.
