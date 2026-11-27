# MoonKeeper

**简体中文** · [English](README.en.md)

MoonKeeper 是用 MoonBit 实现的 Apache ZooKeeper 客户端。你可以用它读取配置并监听变化，用临时顺序节点注册服务，或用一个原子事务同时更新多个节点。网络客户端直接通过 TCP 与 ZooKeeper 通信。

## 从 Mooncakes 安装

在自己的 MoonBit 项目根目录执行：

```sh
moon add backaccouup/moonkeeper@0.1.0
```

在使用网络客户端的 `moon.pkg` 中加入以下配置，然后运行 `moon check --target native`。本版使用 `moonc 1.0.0-rc1+3c0520448` 构建和测试。[Mooncakes 包页面](https://mooncakes.io/docs/backaccouup/moonkeeper/)

```moonbit
import {
  "backaccouup/moonkeeper/client",
}
supported_targets = "native"
```

## 五分钟试用

准备 MoonBit 工具链、C 编译器和 ZooKeeper 3.9.3。下面使用本地测试实例，监听 `127.0.0.1:21819`。在空的测试实例中执行：

```sh
moon update
docker compose -f integration/compose.yaml up -d --wait
moon run cmd/keeper -- --servers 127.0.0.1:21819 create /keeper-demo --text hello
moon run cmd/keeper -- --servers 127.0.0.1:21819 get /keeper-demo
moon run cmd/keeper -- --servers 127.0.0.1:21819 watch /keeper-demo --kind data
```

`get` 输出 Base64，示例值是 `aGVsbG8=`。保持 Watch 命令运行，在第二个终端修改数据。第一个终端收到一次 `NodeDataChanged` 后退出。

```sh
moon run cmd/keeper -- --servers 127.0.0.1:21819 set /keeper-demo --version 0 --text world
moon run cmd/keeper -- --servers 127.0.0.1:21819 delete /keeper-demo --version 1
docker compose -f integration/compose.yaml down --volumes
```

已有 ZooKeeper 时，直接将命令中的地址换成自己的测试服务。配置监听与服务注册两个完整示例的启动、观察和清理步骤见[使用手册](docs/usage.md)。

## 能力与入口

| 能力 | 使用方式 |
| --- | --- |
| 节点和版本 | `create`、`get_data`、`set_data`、`delete`、`exists`。支持中文路径、可空二进制数据、版本条件和完整 Stat。 |
| 服务发现 | 持久、临时及其顺序模式，列举直接子节点及父节点 Stat。创建结果返回服务端实际分配的路径。 |
| 通知 | `watch_exists`、`watch_data`、`watch_children` 返回读取结果和一次性 Watch。收到通知后重新读取并注册。 |
| 权限 | Digest 身份认证、显式创建 ACL、读取 ACL 和按 ACL 版本修改权限。[认证与 ACL](docs/acl.md) |
| 原子事务 | `multi` 支持 Create、SetData、Delete 和 Check。返回逐项结果和事务是否提交。[事务示例](docs/transactions.md) |
| 会话 | 按 xid 分发并发请求、空闲心跳、限时关闭。提供备用地址和恢复策略后，可在原会话内恢复凭据和 Watch。[会话与失败语义](docs/semantics.md) |

根协议包为 `backaccouup/moonkeeper`，native 客户端包为 `backaccouup/moonkeeper/client`。CLI 使用本地安装的 MoonBit 编译运行，默认后端为 native。

## 构建与验证

```sh
moon fmt --check
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
```

真实服务验收包括单节点测试、与 Kazoo 的双向读写和三节点故障切换。工具链版本、Windows/Linux 命令及测试边界见[兼容性与验收](docs/compatibility.md)。本版使用普通 TCP 和一次性 Watch。TLS、SASL、持久或递归 Watch、TTL/container 节点及集群动态配置不在首版范围内。

[Apache-2.0 许可证](LICENSE)
