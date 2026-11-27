# Compatibility and acceptance / 兼容性与验收

MoonKeeper targets ZooKeeper 3.9.3. The build uses moonc 1.0.0-rc1+3c0520448, moon 0.1.20261126 and `moonbitlang/async@0.22.11`. The root protocol package builds for native, JavaScript, wasm and wasm-gc. The socket client, CLI and network examples target native. Run from a clone of this repository with a C compiler and Node.js available.

| Environment | Verification |
| --- | --- |
| Windows x64, Java 17, ZooKeeper 3.9.3 | Windows native build, local TCP fixtures, single-server integration and three JVMs running as one ensemble. |
| Ubuntu 24.04, ZooKeeper 3.9.3 | GitHub Actions builds and tests all four targets, runs single-server tests against Docker and stops two members of a three-container ensemble. See the [CI run history](https://github.com/backaccouup/MoonKeeper/actions/workflows/ci.yml) for each revision. |
| Windows Server 2022 runner | The CI workflow builds and runs the native tests with the pinned MoonBit toolchain. |
| Other ZooKeeper versions and macOS | Interoperability has yet to be verified. |

## Reproduce the checks

```sh
moon update
moon fmt --check
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
```

Single-server tests use Python 3.9+ and Kazoo as an independent observer. Install the test dependencies in a Python environment of your choice, then select one entry point below.

```sh
python -m pip install -r integration/requirements.txt
bash scripts/integration.sh single
# Or use a disposable existing ZooKeeper server
bash scripts/integration.sh existing 127.0.0.1 2181
```

```powershell
python -m pip install -r integration/requirements.txt
./scripts/integration.ps1 -Mode single
# Or use a disposable existing ZooKeeper server
./scripts/integration.ps1 -Mode existing -Port 2181
```

The scripts perform a handshake before exercising CRUD, node modes, watches, ACLs, transactions and CLI scenarios. The independent Kazoo client compares binary data, versions, ACLs, notifications, sequential paths and the effects of a transaction. One test lets ZooKeeper commit a transaction and drops its reply. It checks that the MoonBit client reports an unknown outcome, reconnects and creates exactly one sequential child.

## Three-node failover

```sh
python integration/cluster.py --backend docker
# With Java and the ZooKeeper 3.9.3 binary distribution in ZOOKEEPER_HOME
python integration/cluster.py --backend java
```

`bash scripts/integration.sh cluster` and `./scripts/integration.ps1 -Mode cluster` select an available backend automatically. Each run starts its own temporary ensemble. The test authenticates a client, creates a private ephemeral znode and installs a data watch. It stops the connected server, checks the original session ID and owner, writes to the restricted node and consumes the restored watch. It then removes quorum and waits for the session's safe recovery deadline. Reads from the expired client must fail. The runner bounds each phase and tears down its own services.

测试用凭据由测试进程生成。Kazoo、Python 和 ZooKeeper 服务端都属于验收环境，MoonKeeper 客户端本身只依赖 MoonBit 与 native 异步运行时。
