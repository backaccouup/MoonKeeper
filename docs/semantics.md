# Client semantics / 客户端语义

Current native client calls are serialized on a single TCP connection. `exists(path)` uses a positive, increasing request ID and returns a full `Stat` or `None` only for ZooKeeper's `NoNode` error (`-101`). Other server error codes remain explicit. Paths are validated before sending; a bad path does not poison an established connection.

当前 native 客户端在一条 TCP 连接上串行执行调用。`exists(path)` 使用递增正数请求 ID；仅服务端 `NoNode`（`-101`）会返回 `None`。其他服务端错误保留错误码。路径在发送前验证，非法路径不会断开已建立的连接。

`request_timeout_ms` bounds each `exists` call, including waiting for the local request lock. A timeout closes TCP and moves the client to `Disconnected`, avoiding confusion between a late response and a later request. This status does not establish that the server has expired the session. Neither heartbeat nor reconnection is available yet; a new client scope is required for further operations.

`request_timeout_ms` 包括等待本地请求锁的时间。请求超时后关闭 TCP 并将状态置为 `Disconnected`，避免迟到响应误配后续请求；这不等于确认服务端会话过期。尚无心跳和重连，后续操作须新建客户端作用域。

`close()` is idempotent and closes the socket. Leaving `with_client` also closes it. The current release does not send the ZooKeeper `closeSession` request, so server-side session cleanup follows the negotiated timeout. Concurrent request dispatch, heartbeats, queued request limits, and session-state notifications remain later work.

`close()` 可重复调用，`with_client` 退出也会关闭连接。当前尚未发送 ZooKeeper `closeSession` 请求，服务端会话依协商超时清理。并发分发、心跳、排队上限和会话状态通知仍待实现。
