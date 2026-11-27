# Digest 认证与节点 ACL

使用 `client.add_auth("digest", credential)` 把身份加入当前会话。传入 UTF-8 编码的 `用户名:密码` 字节。这次调用在收到 ZooKeeper 的认证回复后返回。不同会话须分别认证，同一会话可依次添加多个身份。同时调用两次 `add_auth` 时，第二个调用会收到 `QueueFull`。

下面的函数把节点及其数据限定给创建者。调用方通过应用自己的凭据存储提供 `credential`，路径的父节点须已存在并允许创建子节点。

```moonbit
async fn create_private(
  client : @client.Client,
  path : String,
  credential : Bytes,
) -> Unit {
  client.add_auth("digest", credential)
  let options = @moonkeeper.CreateOptions::new(Persistent, @moonkeeper.creator_acl())
  ignore(client.create(path, Some(b"private"), options))
}
```

`creator_acl()` 请求 ZooKeeper 将 `auth` 条目展开为当前已认证的身份，并授予五项权限。管理多个独立身份时，可以从各身份创建的专属节点上以 ADMIN 权限调用 `get_acl`，取得服务器生成的 `digest` 身份，再将需要的条目加入目标节点。直接指定 `digest` 条目时，默认身份格式为 `用户名:Base64(SHA1(用户名:密码))`。密码只通过认证调用传入。服务器可以配置其他摘要算法。[ZooKeeper 3.9.3 Digest 实现](https://github.com/apache/zookeeper/blob/release-3.9.3/zookeeper-server/src/main/java/org/apache/zookeeper/server/auth/DigestAuthenticationProvider.java)

| 常量 | 授权操作 |
| --- | --- |
| `PERM_READ` | 读取节点数据、列出子节点 |
| `PERM_WRITE` | 修改节点数据 |
| `PERM_CREATE` | 在该节点下创建子节点 |
| `PERM_DELETE` | 删除该节点的子节点 |
| `PERM_ADMIN` | 更改节点 ACL |
| `PERM_ALL` | 以上全部权限 |

用按位或组合权限，例如 `@moonkeeper.PERM_READ | @moonkeeper.PERM_WRITE`。每个节点都有自己的 ACL。调用 `client.get_acl(path)` 获取条目及 Stat，随后以 `client.set_acl(path, entries, stat.aversion)` 替换整个 ACL。返回 Stat 的 `aversion` 是新的 ACL 版本。传入 `-1` 跳过版本检查。权限不足返回 `ClientError::Server(-102)`，版本过期返回 `ClientError::Server(-103)`。[ZooKeeper 权限和 ACL 语义](https://zookeeper.apache.org/doc/r3.9.3/zookeeperProgrammers.html#sc_ZooKeeperAccessControl)

ACL 控制服务端的访问授权。MoonKeeper 当前使用普通 TCP，凭据和数据在网络上以明文传输。请在受保护的网络连接上使用 Digest，并将凭据排除在日志、终端输出及命令行参数之外。
