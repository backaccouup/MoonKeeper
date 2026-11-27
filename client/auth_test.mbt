// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn receive_auth_header(conn : @socket.Tcp) -> Unit {
  guard conn.read_exactly(4) is [i32be(size)] else {
    fail("invalid frame length")
  }
  let payload = conn.read_exactly(size)
  assert_eq(
    payload[:12].to_owned(),
    int32_wire(-4) + int32_wire(100) + int32_wire(0),
  )
}

///|
async test "auth waits for its reserved reply and preserves ordinary xid allocation" {
  let mut authenticated = false
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      receive_auth_header(conn)
      @async.sleep(20)
      assert_false(authenticated)
      conn.write(watched_reply(-2, 0) + watched_reply(-4, 0))
      guard conn.read_exactly(4) is [i32be(length)] else {
        fail("request length")
      }
      let get_acl = conn.read_exactly(length)
      assert_eq(get_acl[:8].to_owned(), int32_wire(1) + int32_wire(6))
      conn.write(watched_reply(1, -777))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        client.add_auth("digest", b"unit:temporary")
        authenticated = true
        try {
          ignore(client.get_acl("/x"))
          fail("expected server rejection")
        } catch {
          @client.ClientError::Server(-777) => ()
          _ => fail("server error code lost")
        }
      })
    },
  )
}

///|
async test "auth rejection reaches caller and ends session" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      receive_auth_header(conn)
      conn.write(watched_reply(-4, -115))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        try {
          client.add_auth("digest", b"unit:temporary")
          fail("expected AuthFailed")
        } catch {
          @client.ClientError::Server(-115) => ()
          _ => fail("authentication rejection lost")
        }
        assert_eq(client.state(), @client.ClientState::AuthFailed)
      })
    },
  )
}

///|
async test "overlapping digest requests cannot consume each other's reserved reply" {
  let received : @aqueue.Queue[Unit] = @aqueue.Queue::Queue(kind=Blocking(1))
  let release : @aqueue.Queue[Unit] = @aqueue.Queue::Queue(kind=Blocking(1))
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      receive_auth_header(conn)
      received.put(())
      release.get()
      conn.write(watched_reply(-4, 0))
      receive_auth_header(conn)
      conn.write(watched_reply(-4, 0))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        @async.with_task_group(group => {
          let first = group.spawn(() => client.add_auth("digest", b"a:one"))
          received.get()
          try {
            client.add_auth("digest", b"b:two")
            fail("expected QueueFull")
          } catch {
            @client.ClientError::QueueFull => ()
            _ => fail("unexpected authentication result")
          }
          release.put(())
          first.wait()
          client.add_auth("digest", b"b:two")
        })
      })
    },
  )
}
