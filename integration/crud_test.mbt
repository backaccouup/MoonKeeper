// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "two real clients verify persistent CRUD and version conditions" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT or run scripts/integration.ps1")
  }
  let endpoint = @client.Endpoint::new(host, port~)
  let options = @client.ClientOptions::new(endpoint)
  @client.with_client(options, first => {
    let path = "/moonkeeper-\{first.session_info().session_id}-中文"
    let create_options = @moonkeeper.CreateOptions::new(
      @moonkeeper.CreateMode::Persistent,
      @moonkeeper.open_acl_unsafe(),
    )
    assert_eq(first.create(path, None, create_options), path)
    @client.with_client(options, second => {
      let initial = second.get_data(path)
      assert_eq(initial.data, None)
      assert_eq(initial.stat.version, 0)
      let empty = second.set_data(path, Some(b""), 0)
      assert_eq(empty.version, 1)
      try {
        ignore(first.set_data(path, Some(b"stale"), 0))
        fail("expected BadVersion")
      } catch {
        @client.ClientError::Server(-103) => ()
        err => fail("unexpected: \{err}")
      }
      let unchanged = first.get_data(path)
      assert_eq(unchanged.data, Some(b""))
      assert_eq(unchanged.stat.version, 1)
      assert_eq(first.set_data(path, Some(b"\x00\xff"), 1).version, 2)
      assert_eq(second.get_data(path).data, Some(b"\x00\xff"))
      try {
        ignore(second.create(path, None, create_options))
        fail("expected NodeExists")
      } catch {
        @client.ClientError::Server(-110) => ()
        err => fail("unexpected: \{err}")
      }
      try {
        ignore(second.create(path + "/missing/child", None, create_options))
        fail("expected NoNode")
      } catch {
        @client.ClientError::Server(-101) => ()
        err => fail("unexpected: \{err}")
      }
      let child = path + "/child"
      assert_eq(second.create(child, None, create_options), child)
      try {
        first.delete(path, -1)
        fail("expected NotEmpty")
      } catch {
        @client.ClientError::Server(-111) => ()
        err => fail("unexpected: \{err}")
      }
      second.delete(child, -1)
      first.delete(path, 2)
      assert_eq(second.exists(path), None)
    })
  })
}
