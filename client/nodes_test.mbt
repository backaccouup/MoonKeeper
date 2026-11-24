// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "exists returns None for no node and keeps distinct xids" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      for xid in [1, 2] {
        let request = conn.read_exactly(4)
        let length = match request {
          [i32be(n)] => n
          _ => fail("length")
        }
        let payload = conn.read_exactly(length)
        let header = match payload {
          [i32be(n), i32be(3), ..] => n
          _ => fail("exists")
        }
        assert_eq(header, xid)
        let reply = @buffer.Buffer()
        reply.write_int_be(16)
        reply.write_int_be(xid)
        reply.write_int64_be(0L)
        reply.write_int_be(-101)
        conn.write(reply.to_bytes())
      }
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        assert_eq(client.exists("/missing"), None)
        assert_eq(client.exists("/missing-again"), None)
        client.close()
        client.close()
        assert_eq(client.state(), @client.ClientState::Closed)
      })
    },
  )
}

///|
async test "exists timeout closes the connection and is not session expiry" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let header = conn.read_exactly(4)
      let size = match header {
        [i32be(n)] => n
        _ => fail("size")
      }
      ignore(conn.read_exactly(size))
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(endpoint, request_timeout_ms=50),
        client => {
          try {
            ignore(client.exists("/missing"))
            fail("expected request timeout")
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
async test "invalid path leaves an established session usable" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let header = conn.read_exactly(4)
      let size = match header {
        [i32be(n)] => n
        _ => fail("size")
      }
      ignore(conn.read_exactly(size))
      conn.write(
        b"\x00\x00\x00\x10\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\x9b",
      )
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        try {
          ignore(client.exists("/bad/../path"))
          fail("expected invalid path")
        } catch {
          @client.ClientError::Protocol(
            @moonkeeper.ProtocolError::InvalidPath(_)
          ) => ()
          err => fail("unexpected: \{err}")
        }
        assert_eq(client.state(), @client.ClientState::Connected)
        assert_eq(client.exists("/ok"), None)
      })
    },
  )
}
