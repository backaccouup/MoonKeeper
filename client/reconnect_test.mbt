// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "recovery watermark survives disconnection between notifications from one transaction" {
  with_peer(
    backup => {
      let handshake = backup.read_exactly(49)
      guard handshake is [i32be(45), i32be(0), i64be(watermark), ..] else {
        fail("resume handshake")
      }
      assert_eq(watermark, 1L)
      backup.write(fixture())
      let restore = @moonkeeper.encode_set_watches(1L, [], ["/y"], [])
      assert_eq(backup.read_exactly(restore.length()), restore)
      backup.write(watched_notification(1, b"/y") + watched_reply(-8, 0))
      ignore(backup.read_some())
    },
    fallback => {
      with_peer(
        primary => {
          ignore(primary.read_exactly(49))
          primary.write(fixture())
          watched_request(primary, 1, 3)
          primary.write(watched_reply(1, -101))
          watched_request(primary, 2, 3)
          let notified = watched_notification(1, b"/x")
          let event = notified[:8].to_owned() +
            b"\x00\x00\x00\x00\x00\x00\x00\x09" +
            notified[16:].to_owned()
          primary.write(watched_reply(2, -101) + event)
        },
        endpoint => {
          @client.with_client(
            @client.ClientOptions::new(
              endpoint,
              fallback_endpoints=[fallback],
              reconnect=Some(@client.ReconnectPolicy::new()),
            ),
            client => {
              let (_, first) = client.watch_exists("/x")
              let (_, second) = client.watch_exists("/y")
              assert_eq(first.next_event().unwrap().path, "/x")
              assert_eq(second.next_event().unwrap().path, "/y")
              assert_eq(
                client.next_state_event(),
                Some(@client.ClientState::Disconnected),
              )
              assert_eq(
                client.next_state_event(),
                Some(@client.ClientState::Connected),
              )
            },
          )
        },
      )
    },
  )
}

///|
async test "refusal to resume ends the old session and its watches" {
  with_peer(
    backup => {
      let request = backup.read_exactly(49)
      guard request
        is [i32be(45), i32be(0), i64be(_), i32be(_), i64be(id), i32be(16), ..] else {
        fail("handshake")
      }
      assert_eq(id, 0x0102030405060708L)
      assert_eq(request[32:48].to_owned(), b"0123456789abcdef")
      // ZooKeeper signals a refused resume through a zero negotiated timeout.
      backup.write(
        fixture()[:8].to_owned() + int32_wire(0) + fixture()[12:].to_owned(),
      )
    },
    fallback => {
      with_peer(
        primary => {
          ignore(primary.read_exactly(49))
          primary.write(fixture())
          watched_request(primary, 1, 3)
          primary.write(watched_reply(1, -101))
        },
        first => {
          @client.with_client(
            @client.ClientOptions::new(
              first,
              fallback_endpoints=[fallback],
              reconnect=Some(@client.ReconnectPolicy::new()),
            ),
            client => {
              let (_, watch) = client.watch_exists("/before")
              assert_eq(
                client.next_state_event(),
                Some(@client.ClientState::Disconnected),
              )
              assert_eq(
                client.next_state_event(),
                Some(@client.ClientState::Expired),
              )
              assert_eq(watch.next_event(), None)
              try {
                ignore(client.exists("/after"))
                fail("replaced expired session")
              } catch {
                @client.ClientError::Disconnected => ()
                e => raise e
              }
            },
          )
        },
      )
    },
  )
}
