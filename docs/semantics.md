# Client semantics / 客户端语义

Current native client calls are serialized on a single TCP connection. Each operation uses a positive, increasing request ID. `exists(path)` returns a full `Stat` or `None` only for ZooKeeper's `NoNode` error (`-101`). Other server error codes remain explicit. Paths are validated before sending; a bad path does not poison an established connection.

当前 native 客户端在一条 TCP 连接上串行执行调用，每次操作使用递增正数请求 ID。`exists(path)` 仅在服务端返回 `NoNode`（`-101`）时返回 `None`。其他服务端错误保留错误码。路径在发送前验证，非法路径不会断开已建立的连接。

`request_timeout_ms` bounds each call, including waiting for the local request lock. A timeout closes TCP and moves the client to `Disconnected`, avoiding confusion between a late response and a later request. This status does not establish that the server has expired the session. Idle connections send heartbeats. Reconnection is not available yet; a new client scope is required for further operations.

`request_timeout_ms` 包括等待本地请求锁的时间。请求超时后关闭 TCP 并将状态置为 `Disconnected`，避免迟到响应误配后续请求；这不等于确认服务端会话过期。空闲连接会发送心跳；尚无自动重连，后续操作须新建客户端作用域。

`close()` is idempotent and closes the socket. Leaving `with_client` also closes it. The current release does not send the ZooKeeper `closeSession` request, so server-side session cleanup follows the negotiated timeout. Concurrent request dispatch and queued request limits remain later work.

`close()` 可重复调用，`with_client` 退出也会关闭连接。当前尚未发送 ZooKeeper `closeSession` 请求，服务端会话依协商超时清理。并发请求和排队上限仍待实现。

## One-shot watches / 一次性监听

`watch_exists`, `watch_data`, and `watch_children` install an ordinary ZooKeeper one-shot watch as a side effect of a read. The returned `Watch` yields at most one node event through `next_event()`; later calls return `None`. `watch_exists` also registers when the node is absent and returns `None` for that read. Multiple local subscriptions on the same path can each receive the single server notification. `watch.cancel()` only stops local consumption; it does not call server `removeWatches`.

三个 `watch_*` 方法在读取时注册 ZooKeeper 一次性监听。返回的 `Watch` 通过 `next_event()` 至多取得一次节点通知，之后返回 `None`。`watch_exists` 在节点不存在时仍可注册，并把本次读取表示为 `None`。同一路径多个本地订阅可分别收到同一服务端通知。`watch.cancel()` 只取消本地消费，不调用服务端 `removeWatches`。

After an event, read the node or child list again and register a new watch. The notification means something changed, not that every intermediate change was captured. Data watches respond to data changes or deletion; child watches respond to direct child changes or deletion; existence watches can also observe creation. Notifications are routed independently of ordinary replies and heartbeat replies. The receiver never waits for user event handling. If the total pending-event budget is full, the affected subscription ends with `WatchOverflow`; callers must reread and register again. `next_state_event()` exposes session state separately; a disconnect is never reported as a node change.

收到事件后应重新读取节点或子节点列表，并重新注册监听。通知只说明发生了变化，不保证捕获其间每次修改。数据监听响应数据变化或删除；子节点监听响应直接子节点变化或删除；存在性监听还可响应创建。通知、普通响应和心跳响应分开分发，网络接收不会等待应用消费事件。待消费事件总数超过上限时，受影响订阅以 `WatchOverflow` 结束，调用方须重新读取和注册。`next_state_event()` 独立报告会话状态，不把断线报告为节点变化。

Semantics follow the [ZooKeeper Programmer's Guide on watches](https://zookeeper.apache.org/doc/r3.9.3/zookeeperProgrammers.html#ch_zkWatches). This client does not restore watches after disconnection, because session reconnection is not implemented.

## Persistent znode writes / 持久节点写入

`create`, `get_data`, `set_data`, and `delete` share the serial request channel. Create requires an explicit ACL and supports the four basic persistent, ephemeral, and sequential modes. The named `open_acl_unsafe()` helper grants all permissions to `world:anyone`. Null data and zero-length data are distinct. The full encoded request, including path, data, ACL, and headers, must fit the configured frame limit and the library's 1 MiB ceiling.

四种 CRUD 操作共用串行请求通道。创建时必须显式选择 ACL，支持持久、临时及其顺序模式。`open_acl_unsafe()` 给予 `world:anyone` 全部权限。null 数据和零字节数据不同。请求的路径、数据、ACL 和头部都计入帧上限，库另有 1 MiB 总上限。

Version `-1` bypasses the version check for set/delete; nonnegative versions require a match, and less than `-1` fails locally. Server failures such as `NoNode`, `NodeExists`, `BadVersion`, and `NotEmpty` remain `ClientError::Server(code)`. A failed write before any bytes can be sent is an ordinary local error. Once writing begins, a lost connection, timeout, or invalid response becomes `OutcomeUnknown`: the operation may have committed. The client closes that connection; callers should inspect server state with a new connection before retrying.

修改和删除的 `version=-1` 不检查版本；非负值要求匹配；小于 -1 的值在本地拒绝。`NoNode`、`NodeExists`、`BadVersion` 和 `NotEmpty` 等服务端错误保留为 `ClientError::Server(code)`。发送前的失败是确定的本地错误。开始发送后，断线、超时或无效响应返回 `OutcomeUnknown`，操作可能已经提交。客户端随后关闭该连接；重试前应使用新连接核对服务端状态。

## Children and ephemeral sessions / 子节点与临时会话

`get_children` uses `getChildren` and returns direct child names in server order. `get_children_with_stat` uses `getChildren2` and includes the parent's full `Stat`. Neither method sorts the names or installs a watch. Sequential creation accepts a prefix ending in `/`; the returned path is always the server's actual path. The `Ephemeral` and `EphemeralSequential` flags attach the node to the current server session. ZooKeeper rejects children of ephemeral nodes.

`get_children` 返回服务端顺序的直接子节点名；`get_children_with_stat` 还返回父节点的完整 `Stat`。两者均不排序，也不注册 Watch。顺序创建可接受以 `/` 结尾的前缀，返回路径以服务端结果为准。两种临时节点模式将节点绑定到当前服务端会话，服务端禁止临时节点拥有子节点。

A brief TCP disconnection alone does not prove session expiry: a session might still be valid and its ephemeral nodes might still exist. This client currently cannot resume it. `close()` only closes TCP; it does not send `closeSession`. Ephemeral nodes disappear when ZooKeeper expires the session after the negotiated timeout, rather than immediately on local close. Persistent nodes survive that expiry. Applications must not treat an ephemeral node as a prompt failure detector.

短暂 TCP 断连不代表会话已过期，临时节点可能仍在；当前客户端也不能恢复该会话。`close()` 只关闭 TCP，不发送 `closeSession`。临时节点在 ZooKeeper 按协商超时确认会话过期后删除，并非本地关闭时立即删除；持久节点继续保留。应用不能把临时节点当成立即生效的故障探测信号。
