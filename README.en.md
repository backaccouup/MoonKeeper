# MoonKeeper

[简体中文](README.md) · **English**

MoonKeeper is a MoonBit client for Apache ZooKeeper. It speaks the wire protocol over native TCP. Use it to watch configuration, register ephemeral services or commit several znode updates atomically.

## Try a data watch

Use a MoonBit installation with a C compiler and a fresh test server. The supplied Compose file starts ZooKeeper 3.9.3 on the loopback interface.

```sh
moon update
docker compose -f integration/compose.yaml up -d --wait
moon run cmd/keeper -- --servers 127.0.0.1:21819 create /keeper-demo --text hello
moon run cmd/keeper -- --servers 127.0.0.1:21819 get /keeper-demo
moon run cmd/keeper -- --servers 127.0.0.1:21819 watch /keeper-demo --kind data
```

The read prints `aGVsbG8=`, the Base64 representation of the stored bytes. Leave the watch running. In a second terminal update the data to trigger a single `NodeDataChanged` notification, then clean up.

```sh
moon run cmd/keeper -- --servers 127.0.0.1:21819 set /keeper-demo --version 0 --text world
moon run cmd/keeper -- --servers 127.0.0.1:21819 delete /keeper-demo --version 1
docker compose -f integration/compose.yaml down --volumes
```

## Client API

| Capability | Entry points |
| --- | --- |
| Binary data, versions and metadata | `create`, `get_data`, `set_data`, `delete`, `exists`. Null and empty data are distinct. |
| Service discovery | Persistent and ephemeral nodes, sequential names, `get_children` and `get_children_with_stat`. |
| Notifications | `watch_exists`, `watch_data`, `watch_children`. Each read installs a one-shot watch. Read and register again after an event. |
| Access control | Digest authentication, creator ACLs, ACL reads and conditional writes. [Authentication and ACLs](docs/acl.md) |
| Atomic writes | Create, SetData, Delete and Check in a single `multi` request with ordered results. [Transactions](docs/transactions.md) |
| Sessions | Concurrent request dispatch, heartbeats, scoped close and optional session recovery across endpoints. [Failure semantics](docs/semantics.md) |

Build from source. The portable protocol package is `Mr-Shi123/moonkeeper`. The network package is `Mr-Shi123/moonkeeper/client` and targets native. The CLI and two executable examples use the public client API. [CLI and examples](docs/usage.md)

## Verification

```sh
moon fmt --check
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
```

The test harness includes a single server, interoperability with Kazoo and failover across a three-server ensemble. It uses ZooKeeper 3.9.3. This version uses plain TCP and ordinary one-shot watches. TLS, SASL, persistent or recursive watches, TTL/container nodes and dynamic quorum configuration are outside its scope. [Compatibility and reproducible tests](docs/compatibility.md)

[Apache-2.0 license](LICENSE)
