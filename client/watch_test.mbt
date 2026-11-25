// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn watched_reply(xid : Int32, error : Int32, body~ : Bytes = b"") -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(16 + body.length())
  out.write_int_be(xid)
  out.write_int64_be(1L)
  out.write_int_be(error)
  out.write_bytes(body)
  out.to_bytes()
}

///|
fn watched_notification(kind : Int32, path : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(28 + path.length())
  out.write_int_be(-1)
  out.write_int64_be(-1L)
  out.write_int_be(0)
  out.write_int_be(kind)
  out.write_int_be(3)
  out.write_int_be(path.length())
  out.write_bytes(path)
  out.to_bytes()
}

///|
fn watched_state(state : Int32) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(28)
  out.write_int_be(-1)
  out.write_int64_be(-1L)
  out.write_int_be(0)
  out.write_int_be(-1)
  out.write_int_be(state)
  out.write_int_be(-1)
  out.to_bytes()
}

///|
async fn watched_request(conn : @socket.Tcp, xid : Int32, op : Int32) -> Unit {
  let length = match conn.read_exactly(4) {
    [i32be(n)] => n
    _ => fail("request length")
  }
  let body = conn.read_exactly(length)
  assert_eq(body[0:8].to_owned(), int32_wire(xid) + int32_wire(op))
  assert_eq(body[length - 1], b'\x01')
}

///|
async test "watch reply immediately followed by notification leaves next ordinary reply intact" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101) + watched_notification(1, b"/x"))
      let length = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("request length")
      }
      let body = conn.read_exactly(length)
      assert_eq(body[0:8].to_owned(), int32_wire(2) + int32_wire(3))
      conn.write(watched_reply(2, -101))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (stat, watch) = client.watch_exists("/x")
        assert_eq(stat, None)
        assert_eq(
          watch.next_event().unwrap().kind,
          @moonkeeper.WatchEventType::NodeCreated,
        )
        assert_eq(watch.next_event(), None)
        assert_eq(client.exists("/other"), None)
      })
    },
  )
}

///|
async test "same path subscriptions each receive one event" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
      watched_request(conn, 2, 3)
      conn.write(watched_reply(2, -101) + watched_notification(1, b"/x"))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, first) = client.watch_exists("/x")
        let (_, second) = client.watch_exists("/x")
        assert_eq(first.next_event().unwrap().path, "/x")
        assert_eq(second.next_event().unwrap().path, "/x")
        assert_eq(first.next_event(), None)
        assert_eq(second.next_event(), None)
      })
    },
  )
}

///|
async test "a notification preceding registration reply belongs only to older watches" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
      watched_request(conn, 2, 3)
      conn.write(
        watched_notification(1, b"/x") +
        watched_reply(2, 0, body=stat_fixture(0)) +
        watched_notification(2, b"/x"),
      )
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, older) = client.watch_exists("/x")
        let (_, newer) = client.watch_exists("/x")
        assert_eq(
          older.next_event().unwrap().kind,
          @moonkeeper.WatchEventType::NodeCreated,
        )
        assert_eq(
          newer.next_event().unwrap().kind,
          @moonkeeper.WatchEventType::NodeDeleted,
        )
      })
    },
  )
}

///|
async test "event budget overflow is explicit and cancellation clears local subscription" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
      watched_request(conn, 2, 3)
      conn.write(
        watched_reply(2, -101) +
        watched_notification(1, b"/a") +
        watched_notification(1, b"/b"),
      )
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(endpoint, event_buffer_capacity=1),
        client => {
          let (_, first) = client.watch_exists("/a")
          let (_, second) = client.watch_exists("/b")
          try {
            ignore(second.next_event())
            fail("expected WatchOverflow")
          } catch {
            @client.ClientError::WatchOverflow => ()
            err => fail("unexpected: \{err}")
          }
          assert_eq(first.next_event().unwrap().path, "/a")
          first.cancel()
          assert_eq(first.next_event(), None)
        },
      )
    },
  )
}

///|
async test "timed out watch registration closes its connection" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(endpoint, request_timeout_ms=50),
        client => {
          try {
            ignore(client.watch_exists("/x"))
            fail("expected timeout")
          } catch {
            @client.ClientError::RequestTimeout => ()
            err => fail("unexpected: \{err}")
          }
          assert_eq(client.state(), @client.ClientState::Disconnected)
        },
      )
    },
  )
}

///|
async test "data and child watches use their own event classes" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 4)
      conn.write(
        watched_reply(1, 0, body=int32_wire(1) + b"v" + stat_fixture(2)) +
        watched_notification(3, b"/x"),
      )
      watched_request(conn, 2, 12)
      conn.write(
        watched_reply(2, 0, body=int32_wire(0) + stat_fixture(2)) +
        watched_notification(4, b"/x"),
      )
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (data, data_watch) = client.watch_data("/x")
        assert_eq(data.data, Some(b"v"))
        assert_eq(data.stat.version, 2)
        assert_eq(
          data_watch.next_event().unwrap().kind,
          @moonkeeper.WatchEventType::NodeDataChanged,
        )
        let (children, child_watch) = client.watch_children("/x")
        assert_eq(children.children.length(), 0)
        assert_eq(children.stat.version, 2)
        assert_eq(
          child_watch.next_event().unwrap().kind,
          @moonkeeper.WatchEventType::NodeChildrenChanged,
        )
      })
    },
  )
}

///|
async test "cancel is local and a later notification does not resurrect it" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
      @async.sleep(20)
      conn.write(watched_notification(1, b"/x"))
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("length")
      }
      ignore(conn.read_exactly(size))
      conn.write(watched_reply(2, -101))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, watch) = client.watch_exists("/x")
        watch.cancel()
        assert_eq(client.exists("/other"), None)
        assert_eq(watch.next_event(), None)
      })
    },
  )
}

///|
async test "cancel after notification clears an unread event" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101) + watched_notification(1, b"/x"))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, watch) = client.watch_exists("/x")
        watch.cancel()
        assert_eq(watch.next_event(), None)
      })
    },
  )
}

///|
async test "session notice is separate from node watch" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101) + watched_state(-112))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, watch) = client.watch_exists("/x")
        assert_eq(client.next_state_event(), Some(@client.ClientState::Expired))
        assert_eq(watch.next_event(), None)
        assert_eq(client.state(), @client.ClientState::Expired)
      })
    },
  )
}

///|
async test "watch consumer does not block heartbeat ping" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      let short_session = fixture()[:8].to_owned() +
        int32_wire(3000) +
        fixture()[12:].to_owned()
      conn.write(short_session)
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("ping length")
      }
      assert_eq(size, 8)
      assert_eq(conn.read_exactly(8), b"\xff\xff\xff\xfe\x00\x00\x00\x0b")
      conn.write(watched_reply(-2, 0) + watched_notification(1, b"/x"))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let (_, watch) = client.watch_exists("/x")
        assert_eq(watch.next_event().unwrap().path, "/x")
        assert_eq(client.state(), @client.ClientState::Connected)
      })
    },
  )
}
