# Atomic transactions / 原子事务

Within a `with_client` scope, pass a nonempty list to `client.multi`. ZooKeeper executes the operations in order and commits all of them together. `Check(path, version)` checks a node's data version without modifying it. A nonnegative version requires an exact match. Version -1 accepts any existing version.

在一次 `multi` 调用中可以组合版本检查、创建、写入和删除。下例假定节点 `/config` 和 `/jobs` 已存在，客户端已通过 Digest 认证。配置版本仍为 3 时，服务器更新配置并创建一个顺序节点。顺序节点的完整路径由服务器返回。

```moonbit
let create = @moonkeeper.CreateOptions::new(
  PersistentSequential,
  @moonkeeper.creator_acl(),
)
let result = client.multi([
  Check("/config", 3),
  SetData("/config", Some(b"v4"), 3),
  Create("/jobs/update-", Some(b"\x00\xff"), create),
])
match result {
  Committed([Checked, DataSet(stat), Created(path)]) =>
    println("version=\{stat.version} job=\{path}")
  Aborted(index, _) => println("transaction failed at operation \{index}")
  _ => fail("unexpected result order")
}
```

| Result | Meaning |
| --- | --- |
| `Committed(results)` | One result for every input operation, in order. Create returns the actual path, setData returns the full Stat, and delete and check return `Deleted` and `Checked`. |
| `Aborted(index, results)` | No operation took effect. The zero-based index identifies the failing operation. `Failed(code)` preserves the ZooKeeper error code. Other entries retain the server status as `NotApplied(0)` for earlier operations or `NotApplied(-2)` for skipped operations. |
| `ClientError::OutcomeUnknown` | Writing began and the client could not confirm a valid final response. The whole transaction may have committed. Read the affected nodes or check an application transaction ID before deciding whether to submit another transaction. |

例如第二项因版本不匹配而失败时，三项操作的返回值通常是 `Aborted(1, [NotApplied(0), Failed(-103), NotApplied(-2)])`。第一项的状态码 0 表示它通过了准备阶段，服务器最终回滚了整批操作。收到 `OutcomeUnknown` 时，客户端不会自动重放事务。可以把唯一业务标识写入顺序节点的数据，以便断线后识别已提交的创建。

The configured frame limit covers the combined request header, all operation headers and bodies, and the end marker. An empty batch or an oversized frame fails locally before any transaction bytes are sent.
