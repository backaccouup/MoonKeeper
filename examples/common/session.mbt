// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub fn options() -> @client.ClientOptions raise {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = @string.parse_int(
    @env.get_env_var("MOONKEEPER_ZK_PORT").unwrap_or("2181"),
  )
  @client.ClientOptions::new(
    @client.Endpoint::new(host, port~),
    reconnect=Some(@client.ReconnectPolicy::new()),
  )
}

///|
pub async fn wait_connected(client : @client.Client) -> Unit {
  for ;; {
    match client.state() {
      Connected => return
      Connecting | Disconnected => {
        guard client.next_state_event() is Some(_) else {
          fail("session ended during recovery")
        }
      }
      Expired => fail("session expired")
      AuthFailed => fail("session authentication failed")
      Closed => fail("session closed")
    }
  }
}
