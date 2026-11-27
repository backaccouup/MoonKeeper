# Sessions and failure semantics / 会话与失败语义

## Requests

The client assigns a positive xid to every ordinary request. The send lock serializes frame writes. A single receiver routes replies to the matching caller, including when multiple requests are outstanding. The default limit is 256 outstanding requests. Admission above the configured limit returns `QueueFull`. The default payload limit is 1 MiB in either direction.

请求超时涵盖等待发送、写入和等待响应。读取超时返回 `RequestTimeout`。完整发送后若响应迟到，客户端保留 xid 的匹配位置直至收到回复或连接关闭。这个位置计入未完成请求上限。帧尚未完整发出时断连会废弃该连接，其他请求也会被唤醒。

A server error keeps its numeric code. Only `exists` and `watch_exists` map `NoNode` to an absent result. A conditional update uses the data version, or the ACL version for `set_acl`. A version of -1 accepts any current version.

写请求开始发送后，若未取得可信响应，调用方收到 `OutcomeUnknown`。先检查实际节点、版本或事务效果，再决定下一步。客户端不会自动重发业务操作，尤其是顺序创建和 multi。

## Sessions and failover

`ClientOptions::new(primary, fallback_endpoints=[...], reconnect=Some(ReconnectPolicy::new()))` enables recovery. Initial connection attempts share the request deadline. After a transport failure, outstanding operations finish, the state changes to `Disconnected`, and new calls fail immediately. Recovery rotates through the configured addresses with capped backoff and jitter. It presents the original session ID, password and last observed zxid. The client replays acknowledged authentication, then restores active watches with ZooKeeper's `setWatches` before announcing `Connected`. Session credentials are private.

会话期限以服务端协商超时和最后一次收到服务端帧的时间计算。恢复遭服务端拒绝，或本地安全恢复期限用尽时，状态变为 `Expired`。服务端认证失败进入 `AuthFailed`。此后需要创建新客户端。一次短暂断连期间，原会话的临时节点可以继续存在。默认的单地址配置未启用恢复，可用 `state()` 查询状态，通过 `next_state_event()` 等待变化。

`close()` is idempotent. On a live connection it attempts to send `closeSession`, then releases the transport and pending callers. The scope also closes on callback errors. External cancellation immediately releases the transport and pending calls. ZooKeeper may retain the session until its negotiated timeout. If the close packet fails to reach ZooKeeper, the server uses its session timeout to remove ephemeral nodes. Observe their disappearance from a second client when cleanup matters.

## Watches

`watch_exists`, `watch_data` and `watch_children` return an initial read and a one-shot subscription. An absent node can be watched for creation. A data watch observes modification or deletion. A children watch observes a change to direct children or deletion of the watched node. Multiple local subscriptions may receive one server event. Cancellation stops local consumption. It does not send `removeWatches`.

收到一次通知后，重新读取并注册以获得最新状态。应用可能错过两次注册之间的中间变化，尤其是断连期间同一路径的创建和删除。订阅超过待消费事件总上限时，受影响的订阅返回 `WatchOverflow`，调用方需要重读并注册。会话状态通过独立队列分发，慢消费者不会阻塞网络读循环。

See the [ZooKeeper watch semantics](https://zookeeper.apache.org/doc/r3.9.3/zookeeperProgrammers.html#ch_zkWatches) and [reference client recovery sequence](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-server/src/main/java/org/apache/zookeeper/ClientCnxn.java).
