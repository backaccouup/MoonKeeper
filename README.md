# MoonKeeper

**简体中文** | [English](README.en.md)

**面向 MoonBit 的 Apache ZooKeeper 原生客户端，正在逐步开发。**

目标是让 MoonBit 应用直接接入 ZooKeeper，使用节点操作、配置监听、服务注册和会话管理。协议与客户端逻辑由 MoonBit 实现。

## 当前状态

这是第一阶段的协议雏形，尚不能连接 ZooKeeper 服务器。

已实现：

- 新会话 `ConnectRequest` 编码，包含四字节大端长度前缀。
- 完整 `ConnectResponse` 帧解码，保留 64 位会话 ID、超时、密码和只读标记。
- 区分空密码与 null，兼容省略 `readOnly` 的旧版响应。
- 截断、负长度、超大帧、字段长度错误及多余字节检查。
- 15 项协议测试和一个无需服务器的离线示例；仅使用 MoonBit 标准库。

TCP、请求调度、节点操作、Watch、认证和会话恢复将在后续阶段实现。当前没有经过真实 ZooKeeper 服务联调，也未发布到 Mooncakes。

## 本地运行

开发基线：`moonc v0.10.19` / `moon 0.1.20261102`。在项目根目录执行：

```sh
moon check --deny-warn
moon test --deny-warn
moon run cmd/main
```

示例生成 49 字节的新会话请求，然后解析一份固定响应样例。输出中的会话信息来自样例，程序不会连接网络，也不会打印会话密码。

检查所有后端（native 需要 C 工具链，JS 需要 Node.js）：

```sh
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
```

## 当前 API

在同一模块的调用包中导入 `"Mr-Shi123/moonkeeper"`，即可使用：

```moonbit
let request = @moonkeeper.encode_connect_request(30000)
// request 可交给未来的传输层发送；当前只生成字节。
```

`encode_connect_request` 只用于新会话：协议版本、last zxid 和会话 ID 均为 0，密码为 16 个零字节。超时必须大于 0；可通过 `read_only=true` 允许连接只读服务器。

`decode_connect_response` 接收包含长度前缀的**单个完整帧**，不缓存分片，也不拆分粘连的多帧。它将有效载荷限制为 1 MiB，这是当前库的本地限制，不是 ZooKeeper 协议的通用上限。

解码成功仅表示字节结构合法，不代表连接成功。未知协议版本、非正超时和密码字段交由后续客户端层判断；例如超时为 0 的拒绝响应仍能被解析。会话密码属于凭据，调用方不应写入日志。

## 项目结构

```text
handshake.mbt         握手编码、解码及错误类型
handshake_test.mbt    独立固定样例与错误边界测试
pkg.generated.mbti   moon info 生成的公共接口
cmd/main/            离线示例
```

## 开发路线

计划按约十个可验证的增量逐步完成；具体提交数量随实现调整。

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 项目基础、握手编解码、测试与离线示例 | 已实现 |
| 2 | 原生 TCP、增量分帧与真实服务器握手 | 待开发 |
| 3 | 请求 ID、响应分发、心跳与超时 | 待开发 |
| 4 | 创建、读取、修改、删除节点 | 待开发 |
| 5 | 子节点、状态、版本条件及临时/顺序节点 | 待开发 |
| 6 | Watch 注册、通知分发及取消边界 | 待开发 |
| 7 | ACL 与 Digest 认证 | 待开发 |
| 8 | 原子多操作 `multi` 与结构化服务错误 | 待开发 |
| 9 | 多地址重连、会话恢复及失败语义 | 待开发 |
| 10 | 集群集成测试、互操作验证、CLI 与完整示例 | 待开发 |

## 协议依据与许可证

本项目依据 Apache ZooKeeper 的公开协议定义独立实现，未封装或复制其他语言客户端的实现。当前握手字段参照 **ZooKeeper 3.9.3**：

- [zookeeper.jute](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/resources/zookeeper.jute)：字段顺序和类型。
- [BinaryInputArchive.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-jute/src/main/java/org/apache/jute/BinaryInputArchive.java)：Jute 整数、buffer 和布尔值语义。
- [ProtocolManager.java](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-server/src/main/java/org/apache/zookeeper/compat/ProtocolManager.java)：旧客户端/服务器的可选只读字段。

测试样例按上述字段手工构造，并非来自真实服务的抓包。后续将补充独立客户端与真实集群验证。

Apache-2.0，见 [LICENSE](LICENSE)。Copyright 2026 Mr-Shi123。MoonKeeper 是独立社区项目，与 Apache ZooKeeper 项目无隶属关系。
