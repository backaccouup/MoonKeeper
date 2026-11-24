# MoonKeeper

**简体中文** | [English](README.en.md)

**面向 MoonBit 的 Apache ZooKeeper 原生客户端，正在逐步开发。**

目标是让 MoonBit 应用直接接入 ZooKeeper，使用节点操作、配置监听、服务注册和会话管理。协议与客户端逻辑由 MoonBit 实现。

## 当前状态

已完成协议雏形和原生 TCP 新会话握手，能够连接真实 ZooKeeper 3.9.3。

已实现：

- 新会话 `ConnectRequest` 编码，包含四字节大端长度前缀。
- 完整 `ConnectResponse` 帧解码，保留 64 位会话 ID、超时、密码和只读标记。
- 区分空密码与 null，兼容省略 `readOnly` 的旧版响应。
- 截断、负长度、超大帧、字段长度错误及多余字节检查。
- 增量分帧，支持任意分片和粘包，在分配正文之前检查长度，并检测 EOF 半帧。
- 单地址 native TCP、连接与握手总超时、协商结果校验，以及作用域退出、异常和取消后的连接关闭。
- 可移植协议测试、本地 TCP/客户端测试，以及单独启用的真实 ZooKeeper 集成测试。

**当前支持连接、握手、四种基本节点创建模式及串行节点读写。** 并发请求分发、心跳、Watch、认证、事务和会话恢复仍待实现。作用域结束时关闭 TCP，暂不发送 `closeSession`；服务端会话随后按协商超时过期。长时间保留回调不会自动维持会话。尚未发布到 Mooncakes。

## 本地运行

开发基线：`moonc v0.10.19+bee578715` / `moon 0.1.20261102`。native 网络包使用 `moonbitlang/async@0.20.3`，需要 C 工具链；协议根包仍只使用标准库。在项目根目录执行：

```sh
moon update
moon check --deny-warn
moon test --deny-warn
moon run cmd/main
```

示例生成 49 字节的新会话请求，然后解析一份固定响应样例。输出中的会话信息来自样例，程序不会连接网络，也不会打印会话密码。

默认后端为 native。已启动 ZooKeeper 时，运行真实连接示例：

```sh
moon run cmd/connect --target native -- 127.0.0.1 2181
```

输出真实会话 ID、协商超时和只读标记，然后关闭连接；失败返回非零退出码。省略地址时使用 `127.0.0.1:2181`，`--help` 显示用法。

检查所有后端（native 需要 C 工具链，JS 需要 Node.js）：

```sh
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
```

协议根包测试 native、JS、wasm、wasm-gc；`client`、`cmd/connect`、`integration` 使用 `supported_targets = "native"` 隔离，不声称其他后端支持网络连接。

## 真实服务集成测试

Docker 模式固定使用 `zookeeper:3.9.3`，绑定本机回环端口，数据放临时文件系统，退出后清理本次 Compose 项目。需要已运行的 Docker Engine 和支持 `--wait` 的 Compose v2：

```powershell
./scripts/integration.ps1 -Mode single
```

```sh
bash scripts/integration.sh single
```

没有 Docker 时，先自行启动 ZooKeeper，然后使用外部服务模式；该模式不会停止外部服务：

```powershell
./scripts/integration.ps1 -Mode existing -HostName 127.0.0.1 -Port 2181
```

```sh
bash scripts/integration.sh existing 127.0.0.1 2181
```

脚本先以真实协议握手检查 readiness，再运行集成测试；缺少依赖、服务不可用或测试失败均返回非零。常规 `moon test` 不启用标记为 `#skip` 的真实服务测试。手动启用时，设置 `MOONKEEPER_ZK_PORT`（`MOONKEEPER_ZK_HOST` 默认为 `127.0.0.1`），运行 `moon test integration --target native --include-skipped --deny-warn`。

验证记录：Windows native 已使用 Java 17 和经 SHA512 校验的官方 ZooKeeper 3.9.3 发行包完成握手与重复新会话测试，PowerShell 和 Git Bash 外部服务入口均已验证。Linux native 和 Docker 路径由 [Native handshake 工作流](https://github.com/backaccouup/MoonKeeper/actions/workflows/native-handshake.yml) 验证，以运行结果为准；macOS 尚未验证。

## 当前 API

### 原生客户端

在 native 包中导入 `"Mr-Shi123/moonkeeper/client"` 和 `"moonbitlang/async"`，设置 `supported_targets = "native"`，在异步函数内调用：

```moonbit
let options = @client.ClientOptions::new(
  @client.Endpoint::new("127.0.0.1", port=2181),
  session_timeout_ms=30000,
  request_timeout_ms=10000,
)
@client.with_client(options, client => {
  let info = client.session_info()
  println(info.session_id)
  let path = "/moonkeeper-demo"
  let create_options = @moonkeeper.CreateOptions::new(
    @moonkeeper.CreateMode::Persistent,
    @moonkeeper.open_acl_unsafe(),
  )
  ignore(client.create(path, Some(b"hello"), create_options))
  let current = client.get_data(path)
  let updated = client.set_data(path, Some(b"world"), current.stat.version)
  client.delete(path, updated.version)
})
```

`with_client[T]` 返回回调的结果，并原样传播回调错误与取消；所有退出路径关闭 TCP。`SessionInfo` 仅包含 `session_id`、`session_timeout_ms`、`read_only`，不含密码。

| 选项 | 默认值 | 当前作用 |
| --- | --- | --- |
| `session_timeout_ms` | 30000 | 请求的会话超时，实际值以服务端协商为准 |
| `request_timeout_ms` | 10000 | 连接、握手和每次串行请求的截止时间，不限制回调总时长 |
| `max_frame_size` | 1048576 | 请求及响应有效载荷字节上限；客户端允许 45—1048576 |
| `read_only` | false | 是否允许只读服务端 |
| `max_pending_requests` | 256 | 为后续请求分发保留，当前无业务请求队列 |
| `event_buffer_capacity` | 256 | 为后续通知管理保留，当前无事件队列 |

`Client::exists(path)` 返回完整 `Stat?`：仅服务端的 `NoNode` 映射为 `None`。`create` 返回实际创建路径；`get_data` 返回 `Bytes?` 和完整 `Stat`；`set_data` 返回更新后的 `Stat`；`delete` 无返回值。数据的 `None` 与空字节数组不同。`CreateOptions` 必须显式指定 ACL；`open_acl_unsafe()` 使用 `world:anyone` 的全部权限，只适合无需访问控制的节点。当前只支持 `Persistent`。修改和删除的 `version=-1` 忽略版本，非负值要求匹配；小于 -1 的值在发送前拒绝。其他服务端错误保留错误码。

`Client::state()` 可查询状态，`Client::close()` 可重复调用并关闭 TCP。请求串行处理，每个连接使用递增正数 xid。读请求超时后关闭连接并进入 `Disconnected`；写请求可能发出后失败时返回 `OutcomeUnknown`，调用方应先核对服务器状态再决定是否重试。详见 [失败与生命周期语义](docs/semantics.md)。示例还需在包配置中导入 `"Mr-Shi123/moonkeeper"`。

`CreateMode` 支持 `Persistent`、`Ephemeral`、`PersistentSequential`、`EphemeralSequential`。顺序节点允许以 `/parent/` 作为创建前缀；`create` 返回服务端生成的完整路径，不能自行推算序号。`get_children(path)` 返回直接子节点的名称数组；`get_children_with_stat(path)` 额外返回父节点的完整 `Stat`。子节点顺序由服务端决定，调用方需要顺序时自行排序。临时节点的 `Stat.ephemeral_owner` 是创建它的会话 ID，临时节点不能拥有子节点。

`ClientError` 区分选项错误、传输失败、握手超时、请求超时、协议错误、服务端错误、会话拒绝和关闭状态。客户端验证协议版本、协商超时、非零会话 ID、16 字节密码和只读许可；错误不包含原始响应或密码。当前模块命名空间仍为 `Mr-Shi123/moonkeeper`，与 GitHub 提交账号分别管理。

### 可移植协议

在同一模块的调用包中导入 `"Mr-Shi123/moonkeeper"`，即可使用：

```moonbit
let request = @moonkeeper.encode_connect_request(30000)
// 此底层函数只生成字节；联网使用上面的 client 包。
```

`encode_connect_request` 只用于新会话：协议版本、last zxid 和会话 ID 均为 0，密码为 16 个零字节。超时必须大于 0；可通过 `read_only=true` 允许连接只读服务器。

`decode_connect_response` 接收包含长度前缀的**单个完整帧**，不缓存分片，也不拆分粘连的多帧。它将有效载荷限制为 1 MiB，这是当前库的本地限制，不是 ZooKeeper 协议的通用上限。

解码成功仅表示字节结构合法，不代表连接成功。协议版本、非正超时和密码字段由 `client` 包进一步验证；例如超时为 0 的拒绝响应仍能被底层解码器解析。会话密码属于凭据，调用方不应写入日志。

流式输入使用 `FrameDecoder::new(max_frame_size=1048576)`，调用 `feed(Bytes)` 获取带四字节长度头的完整帧数组，最后调用 `finish()` 检查半帧。干净的 `finish()` 可以重复调用；结束或出错后再调用 `feed` 会报错。

## 项目结构

```text
handshake.mbt         握手编码、解码及错误类型
handshake_test.mbt    独立固定样例与错误边界测试
frame.mbt             增量分帧；frame_test.mbt 为对应测试
client/               native 连接作用域、传输、错误和本地 TCP 测试
pkg.generated.mbti   moon info 生成的公共接口
cmd/main/            离线示例
cmd/connect/         真实服务器连接示例
integration/         ZooKeeper 3.9.3 环境及真实服务测试
scripts/             PowerShell / Bash 集成入口
```

## 开发路线

在已有协议雏形基础上按十个功能增量推进；文档维护提交单独记录，功能阶段不等于 Git 提交总数。

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 项目基础、握手编解码、测试与离线示例 | 已实现 |
| 2 | 原生 TCP、增量分帧与真实服务器握手 | 已实现 |
| 3 | 请求 ID、响应分发、心跳与超时 | 进行中：串行 exists 与请求超时 |
| 4 | 创建、读取、修改、删除持久节点 | 已实现 |
| 5 | 子节点、状态、版本条件及临时/顺序节点 | 已实现基础能力 |
| 6 | Watch 注册、通知分发及取消边界 | 待开发 |
| 7 | ACL 与 Digest 认证 | 待开发 |
| 8 | 原子多操作 `multi` 与结构化服务错误 | 待开发 |
| 9 | 多地址重连、会话恢复及失败语义 | 待开发 |
| 10 | CLI、配置监听与服务注册示例 | 待开发 |
| 11 | 完整集群故障/互操作验证与交付整理 | 待开发 |

## 协议依据与许可证

本项目依据 Apache ZooKeeper 的公开协议定义独立实现，未封装或复制其他语言客户端的实现。当前握手字段参照 **ZooKeeper 3.9.3**：

- [zookeeper.jute](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/resources/zookeeper.jute)：字段顺序和类型。
- [BinaryInputArchive.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/java/org/apache/jute/BinaryInputArchive.java)：Jute 整数、buffer 和布尔值语义。
- [ProtocolManager.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-server/src/main/java/org/apache/zookeeper/compat/ProtocolManager.java)：旧客户端/服务器的可选只读字段。

固定协议样例按上述字段手工构造，并非真实服务抓包；真实服务器握手由集成测试另行验证。后续将补充独立客户端与真实集群验证。原生异步 I/O 使用 Apache-2.0 的 `moonbitlang/async`。

Apache-2.0，见 [LICENSE](LICENSE)。Copyright 2026 Mr-Shi123；新增代码 Copyright 2026 backaccouup。MoonKeeper 是独立社区项目，与 Apache ZooKeeper 项目无隶属关系。
