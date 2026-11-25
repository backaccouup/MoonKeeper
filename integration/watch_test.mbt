// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "two real clients exchange one-shot data and child watches" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT or run the integration script")
  }
  let options = @client.ClientOptions::new(@client.Endpoint::new(host, port~))
  let create_options = @moonkeeper.CreateOptions::new(
    @moonkeeper.CreateMode::Persistent,
    @moonkeeper.open_acl_unsafe(),
  )
  @client.with_client(options, watcher => {
    let parent = "/moonkeeper-watch-\{watcher.session_info().session_id}"
    let item = parent + "/item"
    let child = parent + "/child"
    assert_eq(watcher.create(parent, None, create_options), parent)
    @client.with_client(options, writer => {
      let (missing, created) = watcher.watch_exists(item)
      assert_eq(missing, None)
      assert_eq(writer.create(item, Some(b"a"), create_options), item)
      assert_eq(
        @async.with_timeout(3000, () => created.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeCreated,
      )
      assert_eq(created.next_event(), None)

      let (initial, changed) = watcher.watch_data(item)
      assert_eq(initial.data, Some(b"a"))
      ignore(writer.set_data(item, Some(b"b"), -1))
      assert_eq(
        @async.with_timeout(3000, () => changed.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeDataChanged,
      )
      ignore(writer.set_data(item, Some(b"c"), -1))
      assert_eq(changed.next_event(), None)
      let (latest, changed_again) = watcher.watch_data(item)
      assert_eq(latest.data, Some(b"c"))
      ignore(writer.set_data(item, Some(b"d"), -1))
      assert_eq(
        @async.with_timeout(3000, () => changed_again.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeDataChanged,
      )

      let (before_add, added) = watcher.watch_children(parent)
      assert_eq(before_add.children.length(), 1)
      assert_eq(writer.create(child, None, create_options), child)
      assert_eq(
        @async.with_timeout(3000, () => added.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeChildrenChanged,
      )
      let (after_add, removed) = watcher.watch_children(parent)
      assert_eq(after_add.children.length(), 2)
      writer.delete(child, -1)
      assert_eq(
        @async.with_timeout(3000, () => removed.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeChildrenChanged,
      )

      let (present, deleted) = watcher.watch_exists(item)
      assert_true(present is Some(_))
      writer.delete(item, -1)
      assert_eq(
        @async.with_timeout(3000, () => deleted.next_event()).unwrap().kind,
        @moonkeeper.WatchEventType::NodeDeleted,
      )
      assert_eq(watcher.get_children(parent).length(), 0)
      watcher.delete(parent, -1)
    })
  })
}
