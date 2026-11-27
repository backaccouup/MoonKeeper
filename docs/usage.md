# MoonKeeper 使用指南

以下命令从仓库根目录运行，需要 native C 工具链、MoonBit 及一个可以连接的 ZooKeeper。示例使用仓库 Compose 配置的回环端口 21819。已有服务时，把命令中的地址换成实际地址即可。

```sh
docker compose -p moonkeeper-demo -f integration/compose.yaml up -d --wait
moon build --target native
moon run cmd/connect --target native -- 127.0.0.1 21819
```

`cmd/connect` 会打印真实的会话 ID 和协商超时。`moon run cmd/main` 可以离线运行，它从内置握手报文读取示例字段。构建输出会列出三个可用于下文的独立程序路径。也可以通过 `moon run` 启动它们。

## 一次读写

先创建本次使用的专属目录。服务会在路径后添加序号。复制返回的完整路径，把下文的 `/demo-0000000001` 替换为它。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 create /demo- --mode persistent-sequential
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 create /demo-0000000001/config --text blue
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 get /demo-0000000001/config
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 set /demo-0000000001/config --version 0 --text green
```

第一次 `get` 输出 `Ymx1ZQ==`，即 UTF-8 文本 `blue` 的 Base64。更新成功输出 `version=1`。再次指定版本 0 更新会得到服务错误 `-103`，可用 `stat` 查看当前版本。

## CLI 命令

通用参数可放在子命令前后。`--servers` 接受逗号分隔的 `host[:port]` 列表，IPv6 地址写成 `[::1]:2181`。默认地址为 `127.0.0.1:2181`。`--request-timeout` 和 `--session-timeout` 的单位为毫秒，默认分别为 10000 和 30000。会话使用服务器协商的有效超时。

| 命令 | 输出或效果 |
| --- | --- |
| `exists PATH` | 输出 `true` 或 `false`。查无节点时退出码仍为 0。 |
| `get PATH [--output FILE]` | 默认输出 Base64。指定文件时覆盖写入原始字节。 |
| `set PATH (--text TEXT 或 --file FILE 或 --null) [--version N]` | 更新数据并输出新版本。 |
| `create PATH [--text TEXT 或 --file FILE 或 --null] [--mode MODE]` | 默认创建持久节点，输出实际路径。省略输入时写入 null。父节点须已存在。 |
| `delete PATH [--version N]` | 删除空节点。 |
| `children PATH` | 每行输出一个直接子节点名称。 |
| `watch PATH [--kind exists 或 data 或 children]` | 默认监听节点的存在性。成功注册后向 stderr 输出 `watch armed`，第一次通知到达时向 stdout 输出事件类型和路径，然后退出。 |
| `stat PATH` | 输出创建与修改 zxid、毫秒时间戳、版本、临时节点所有者及子节点数量等字段。 |

版本条件接受非负整数或 `-1`，默认 `-1` 表示接受任意版本。创建模式为 `persistent`、`ephemeral`、`persistent-sequential`、`ephemeral-sequential`。每次调用 CLI 使用一个独立会话。要让临时节点保持可发现，可运行下文的服务注册示例。

`--file` 逐字节读取数据，`--text` 使用 UTF-8。`get` 对空字节输出空行，对 null 输出 `(null)`。若为 null 请求写文件，程序报告操作失败并保留目标文件内容。以下命令可往返包含零字节的文件。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 set /demo-0000000001/config --file input.bin
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 get /demo-0000000001/config --output copy.bin
```

`keeper --help` 和 `keeper COMMAND --help` 显示命令帮助。直接运行构建出的 `keeper` 时，成功返回 0，命令、输入文件或凭据格式错误返回 2，连接、服务端或输出写入失败返回 1。诊断写入 stderr。写操作报告 `OutcomeUnknown` 时，应先查询节点状态再决定后续操作。

## Digest 身份

`--auth-file FILE` 优先于环境变量 `MOONKEEPER_DIGEST`。文件内容为一行 UTF-8 的 `user:password`，可带末尾 LF 或 CRLF。没有指定来源时，客户端以匿名身份连接。请把凭据文件放在仓库外并限制读取权限。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 --auth-file private.credential get /protected
```

CLI 和示例创建的节点均使用开放 ACL `world:anyone` 的全部权限。登录身份可用于访问已受 ACL 保护的节点。创建受保护节点和更改 ACL 的 API 见 [ACL 与认证](acl.md)。

## 在 MoonBit 中使用客户端

在 native 包的 `moon.pkg` 中导入 `Mr-Shi123/moonkeeper`、`Mr-Shi123/moonkeeper/client` 和 `moonbitlang/async`。以下函数在一个会话内读取数据。回调返回时 `with_client` 关闭会话，读取失败时错误会传给调用方。

```moonbit
async fn read_config(path : String) -> @moonkeeper.DataResult {
  let options = @client.ClientOptions::new(
    @client.Endpoint::new("127.0.0.1", port=21819),
    session_timeout_ms=30000,
    request_timeout_ms=10000,
    reconnect=Some(@client.ReconnectPolicy::new()),
  )
  @client.with_client(options, client => client.get_data(path))
}
```

`DataResult.data` 的类型为 `Bytes?`，`DataResult.stat.version` 可作为下一次 `set_data(path, bytes, version)` 的版本条件。多节点集群可通过 `fallback_endpoints=[...]` 传入备用地址。客户端在原会话上恢复身份与仍有效的监听。可运行的持续订阅代码见 [配置监听示例](../examples/config_watch/main.mbt)，事务结果及失败处理见 [客户端语义](semantics.md)。

## 配置监听

两个示例通过 `MOONKEEPER_ZK_HOST` 和 `MOONKEEPER_ZK_PORT` 指定服务器，默认值为 `127.0.0.1` 和 `2181`。在运行示例的终端配置回环端口。PowerShell 使用 `$env:MOONKEEPER_ZK_PORT = '21819'`，Bash 使用 `export MOONKEEPER_ZK_PORT=21819`。

在终端 A 运行以下命令。最后一个参数 2 表示打印两次快照后退出，省略它会持续监听。

```sh
moon run examples/config_watch --target native -- /demo-0000000001/config 2
```

看到第一行 `version=… data=…` 后，在终端 B 运行以下命令。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 set /demo-0000000001/config --text orange
```

终端 A 会显示递增的版本以及 `data=b3Jhbmdl`。示例每次在同一个请求里读取数据并设置一次性 Watch，收到事件后重新读取。节点消失时打印 `missing` 并监听是否创建。断线期间示例标记旧数据已过时，原会话恢复后重新读取，即使值相同也会打印快照。会话过期时程序终止。

## 临时服务注册

终端 A 保持标准输入打开，运行以下命令。

```sh
moon run examples/service_registration --target native -- /demo-0000000001 localhost:8080
```

程序打印 `registered /demo-0000000001/instance-…`，以会话 ID 构成当前实例的唯一名称。终端 B 查看注册目录，再把上一条命令返回的实例路径传给 `get`。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 children /demo-0000000001
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 get /demo-0000000001/instance-实际会话ID
```

实例数据 `bG9jYWxob3N0OjgwODA=` 解码为 `localhost:8080`。在终端 A 按 Enter 正常关闭会话，再次运行 `children`，实例会从目录消失。进程异常结束时，服务器可能要等到会话过期才清理。创建回包丢失时，示例用原路径核对数据和 `ephemeralOwner`，确认归属后才宣布注册成功。

## 清理与自动演示

删除开头创建的节点，路径仍使用本次运行返回的序号。若本次启动了 Compose 服务，再执行最后一行。

```sh
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 delete /demo-0000000001/config
moon run cmd/keeper --target native -- --servers 127.0.0.1:21819 delete /demo-0000000001
docker compose -p moonkeeper-demo -f integration/compose.yaml down --volumes
```

要自动验证以上场景，先运行 `moon build --target native` 并设置 `MOONKEEPER_ZK_PORT`。然后在 PowerShell 运行 `python integration/cli_scenarios.py`，或在 Bash 运行 `python3 integration/cli_scenarios.py`。该脚本需要 Python 3.9 或更高版本，仅使用标准库。它创建本次运行的唯一测试目录，验证跨进程读写、断线重读及临时节点关闭后的清理，最后删除该目录。
