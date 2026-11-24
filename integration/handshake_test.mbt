// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "real ZooKeeper negotiates distinct sessions over repeated connections" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None =>
      fail(
        "Set MOONKEEPER_ZK_PORT or run scripts/integration.ps1 or integration.sh",
      )
  }
  let options = @client.ClientOptions::new(@client.Endpoint::new(host, port~))
  let first = @client.with_client(options, client => {
    let info = client.session_info()
    assert_true(info.session_id != 0L)
    assert_true(info.session_timeout_ms > 0)
    assert_eq(info.read_only, false)
    info.session_id
  })
  let second = @client.with_client(options, client => {
    client.session_info().session_id
  })
  assert_true(second != 0L && first != second)
}

///|
#skip
async test "real ZooKeeper exists returns root Stat and None for absent node" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT")
  }
  @client.with_client(
    @client.ClientOptions::new(@client.Endpoint::new(host, port~)),
    client => {
      let root = client.exists("/")
      assert_true(root is Some(_))
      assert_eq(client.exists("/moonkeeper-integration-absent-398481"), None)
    },
  )
}
