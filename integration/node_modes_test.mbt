// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "real ZooKeeper children and ephemeral sequential lifecycle" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT or run the integration script")
  }
  let endpoint = @client.Endpoint::new(host, port~)
  let owner_options = @client.ClientOptions::new(
    endpoint,
    session_timeout_ms=4000,
  )
  let observer_options = @client.ClientOptions::new(endpoint)
  let acl = @moonkeeper.open_acl_unsafe()
  @client.with_client(owner_options, owner => {
    let session_id = owner.session_info().session_id
    let parent = "/moonkeeper-modes-\{session_id}"
    let persistent = @moonkeeper.CreateOptions::new(
      @moonkeeper.CreateMode::Persistent,
      acl,
    )
    let ephemeral = @moonkeeper.CreateOptions::new(
      @moonkeeper.CreateMode::Ephemeral,
      acl,
    )
    let ordered = @moonkeeper.CreateOptions::new(
      @moonkeeper.CreateMode::PersistentSequential,
      acl,
    )
    let ephemeral_ordered = @moonkeeper.CreateOptions::new(
      @moonkeeper.CreateMode::EphemeralSequential,
      acl,
    )
    assert_eq(owner.create(parent, None, persistent), parent)
    assert_eq(owner.get_children(parent).length(), 0)
    let live = owner.create(parent + "/live", None, ephemeral)
    let first = owner.create(parent + "/ordered-", None, ordered)
    let second = owner.create(parent + "/ordered-", None, ordered)
    let live_ordered = owner.create(
      parent + "/service-",
      None,
      ephemeral_ordered,
    )
    assert_true(first != second)
    assert_true(first.has_prefix(parent + "/ordered-"))
    assert_true(second.has_prefix(parent + "/ordered-"))
    assert_true(live_ordered.has_prefix(parent + "/service-"))
    @client.with_client(observer_options, observer => {
      assert_eq(observer.exists(live).unwrap().ephemeral_owner, session_id)
      assert_eq(
        observer.exists(live_ordered).unwrap().ephemeral_owner,
        session_id,
      )
      assert_eq(observer.exists(first).unwrap().ephemeral_owner, 0L)
      assert_eq(observer.exists(second).unwrap().ephemeral_owner, 0L)
      let children = observer.get_children_with_stat(parent)
      assert_eq(children.children.length(), 4)
      assert_eq(children.stat.num_children, 4)
      try {
        ignore(observer.create(live + "/child", None, persistent))
        fail("ephemeral parent accepted a child")
      } catch {
        @client.ClientError::Server(-108) => ()
        err => fail("unexpected: \{err}")
      }
      owner.close()
      let deadline = @async.now() +
        owner.session_info().session_timeout_ms.to_int64() * 3L +
        3000L
      let mut gone = false
      while !gone && @async.now() < deadline {
        let plain_gone = observer.exists(live) is None
        let ordered_gone = observer.exists(live_ordered) is None
        gone = plain_gone && ordered_gone
        if !gone {
          @async.sleep(100)
        }
      }
      assert_true(gone)
      assert_true(observer.exists(first) is Some(_))
      assert_true(observer.exists(second) is Some(_))
      observer.delete(first, -1)
      observer.delete(second, -1)
      observer.delete(parent, -1)
    })
  })
}
