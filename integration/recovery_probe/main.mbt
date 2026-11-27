// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn main {
  let args = @env.args()
  guard args.length() == 6 else {
    fail("usage: recovery_probe host port1 port2 port3 signal-directory")
  }
  let endpoints = [2, 3, 4].map(i => {
    @client.Endpoint::new(args[1], port=@string.parse_int(args[i]))
  })
  let options = @client.ClientOptions::new(
    endpoints[0],
    fallback_endpoints=endpoints[1:].to_owned(),
    reconnect=Some(@client.ReconnectPolicy::new(attempts=40)),
    session_timeout_ms=7000,
    request_timeout_ms=3000,
  )
  @async.with_timeout(65000, () => {
    @client.with_client(options, client => {
      let id = client.session_info().session_id
      let path = "/moonkeeper-recovery-\{id}"
      let entropy = @random.Rand::Rand()
      client.add_auth(
        "digest",
        @utf8.encode("member:\{entropy.uint64()}\{entropy.uint64()}"),
      )
      ignore(
        client.create(
          path,
          Some(b"before"),
          @moonkeeper.CreateOptions::new(Ephemeral, @moonkeeper.creator_acl()),
        ),
      )
      let (_, watch) = client.watch_data(path)
      @fs.write_file(args[5] + "/ready", b"", create_mode=CreateOrTruncate)
      assert_eq(
        client.next_state_event(),
        Some(@client.ClientState::Disconnected),
      )
      assert_eq(client.next_state_event(), Some(@client.ClientState::Connected))
      assert_eq(client.session_info().session_id, id)
      assert_eq(client.get_data(path).stat.ephemeral_owner, id)
      // A successful conditional write requires the restored Digest identity.
      ignore(client.set_data(path, Some(b"after"), 0))
      assert_eq(
        watch.next_event().unwrap().kind,
        @moonkeeper.WatchEventType::NodeDataChanged,
      )
      @fs.write_file(args[5] + "/restored", b"", create_mode=CreateOrTruncate)
      assert_eq(
        client.next_state_event(),
        Some(@client.ClientState::Disconnected),
      )
      // The remaining peer can briefly accept a reconnection while the other
      // servers' loss is propagating through the quorum protocol.
      for ;; {
        match client.next_state_event() {
          Some(Expired) => break
          Some(Disconnected) | Some(Connected) => continue
          _ => fail("state stream closed before expiry")
        }
      }
      try {
        ignore(client.get_data(path))
        fail("expired client accepted a request")
      } catch {
        @client.ClientError::Disconnected => ()
        error => raise error
      }
      @fs.write_file(args[5] + "/expired", b"", create_mode=CreateOrTruncate)
    })
  })
}
