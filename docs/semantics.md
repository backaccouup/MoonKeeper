# Client semantics / 客户端语义

Current native client calls are serialized on a single TCP connection. Each operation uses a positive, increasing request ID. `exists(path)` returns a full `Stat` or `None` only for ZooKeeper's `NoNode` error (`-101`). Other server error codes remain explicit. Paths are validated before sending; a bad path does not poison an established connection.

当前 native 客户端在一条 TCP 连接上串行执行调用，每次操作使用递增正数请求 ID。`exists(path)` 仅在服务端返回 `NoNode`（`-101`）时返回 `None`。其他服务端错误保留错误码。路径在发送前验证，非法路径不会断开已建立的连接。

`request_timeout_ms` bounds each call, including waiting for the local request lock. A timeout closes TCP and moves the client to `Disconnected`, avoiding confusion between a late response and a later request. This status does not establish that the server has expired the session. Neither heartbeat nor reconnection is available yet; a new client scope is required for further operations.

`request_timeout_ms` 包括等待本地请求锁的时间。请求超时后关闭 TCP 并将状态置为 `Disconnected`，避免迟到响应误配后续请求；这不等于确认服务端会话过期。尚无心跳和重连，后续操作须新建客户端作用域。

`close()` is idempotent and closes the socket. Leaving `with_client` also closes it. The current release does not send the ZooKeeper `closeSession` request, so server-side session cleanup follows the negotiated timeout. Concurrent request dispatch, heartbeats, queued request limits, and session-state notifications remain later work.

`close()` 可重复调用，`with_client` 退出也会关闭连接。当前尚未发送 ZooKeeper `closeSession` 请求，服务端会话依协商超时清理。并发分发、心跳、排队上限和会话状态通知仍待实现。

## Persistent znode writes / 持久节点写入

`create`, `get_data`, `set_data`, and `delete` share the serial request channel. Create requires an explicit ACL and currently supports only `Persistent`. The named `open_acl_unsafe()` helper grants all permissions to `world:anyone`. Null data and zero-length data are distinct. The full encoded request, including path, data, ACL, and headers, must fit the configured frame limit and the library's 1 MiB ceiling.

四种 CRUD 操作共用串行请求通道。创建时必须显式选择 ACL，当前仅支持持久节点。`open_acl_unsafe()` 给予 `world:anyone` 全部权限。null 数据和零字节数据不同。请求的路径、数据、ACL 和头部都计入帧上限，库另有 1 MiB 总上限。

Version `-1` bypasses the version check for set/delete; nonnegative versions require a match, and less than `-1` fails locally. Server failures such as `NoNode`, `NodeExists`, `BadVersion`, and `NotEmpty` remain `ClientError::Server(code)`. A failed write before any bytes can be sent is an ordinary local error. Once writing begins, a lost connection, timeout, or invalid response becomes `OutcomeUnknown`: the operation may have committed. The client closes that connection; callers should inspect server state with a new connection before retrying.

修改和删除的 `version=-1` 不检查版本；非负值要求匹配；小于 -1 的值在本地拒绝。`NoNode`、`NodeExists`、`BadVersion` 和 `NotEmpty` 等服务端错误保留为 `ClientError::Server(code)`。发送前的失败是确定的本地错误。开始发送后，断线、超时或无效响应返回 `OutcomeUnknown`，操作可能已经提交。客户端随后关闭该连接；重试前应使用新连接核对服务端状态。
