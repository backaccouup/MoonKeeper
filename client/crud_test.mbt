// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "CRUD calls send distinct xids and expose server versions" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      for
        (xid, op, response) in [
          (1, 1, b"\x00\x00\x00\x06/hello"),
          (2, 4, b"\x00\x00\x00\x01a" + stat_fixture(0)),
          (3, 5, stat_fixture(1)),
          (4, 2, b""),
        ] {
        let header = conn.read_exactly(4)
        let size = match header {
          [i32be(n)] => n
          _ => fail("length")
        }
        let payload = conn.read_exactly(size)
        assert_eq(payload[0:8].to_owned(), int32_wire(xid) + int32_wire(op))
        let reply = @buffer.Buffer()
        reply.write_int_be(16 + response.length())
        reply.write_int_be(xid)
        reply.write_int64_be(1L)
        reply.write_int_be(0)
        reply.write_bytes(response)
        conn.write(reply.to_bytes())
      }
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let options = @moonkeeper.CreateOptions::new(
          @moonkeeper.CreateMode::Persistent,
          @moonkeeper.open_acl_unsafe(),
        )
        assert_eq(client.create("/hello", Some(b"a"), options), "/hello")
        let read = client.get_data("/hello")
        assert_eq(read.data, Some(b"a"))
        assert_eq(read.stat.version, 0)
        assert_eq(client.set_data("/hello", Some(b"b"), 0).version, 1)
        client.delete("/hello", 1)
      })
    },
  )
}

///|
fn int32_wire(n : Int32) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(n)
  out.to_bytes()
}

///|
fn stat_fixture(version : Int32) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int64_be(1L)
  out.write_int64_be(2L)
  out.write_int64_be(3L)
  out.write_int64_be(4L)
  out.write_int_be(version)
  out.write_int_be(0)
  out.write_int_be(0)
  out.write_int64_be(0L)
  out.write_int_be(1)
  out.write_int_be(0)
  out.write_int64_be(1L)
  out.to_bytes()
}

///|
async test "write failure after possible send reports unknown outcome" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("length")
      }
      ignore(conn.read_exactly(size))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        try {
          ignore(client.set_data("/x", Some(b"v"), -1))
          fail("expected unknown outcome")
        } catch {
          @client.ClientError::OutcomeUnknown => ()
          err => fail("unexpected: \{err}")
        }
        assert_eq(client.state(), @client.ClientState::Disconnected)
      })
    },
  )
}

///|
async test "invalid version and full frame limit fail before any write" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("length")
      }
      let request = conn.read_exactly(size)
      assert_eq(request[0:8].to_owned(), int32_wire(1) + int32_wire(4))
      let reply = @buffer.Buffer()
      reply.write_int_be(16 + 4 + 68)
      reply.write_int_be(1)
      reply.write_int64_be(1L)
      reply.write_int_be(0)
      reply.write_int_be(-1)
      reply.write_bytes(stat_fixture(0))
      conn.write(reply.to_bytes())
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(endpoint, max_frame_size=100),
        client => {
          try {
            ignore(client.set_data("/x", None, -2))
            fail("expected invalid version")
          } catch {
            @client.ClientError::Protocol(
              @moonkeeper.ProtocolError::InvalidVersion(-2)
            ) => ()
            err => fail("unexpected: \{err}")
          }
          try {
            ignore(client.set_data("/x", Some(Bytes::make(100, b'x')), -1))
            fail("expected oversized frame")
          } catch {
            @client.ClientError::Protocol(
              @moonkeeper.ProtocolError::FrameTooLarge(_)
            ) => ()
            err => fail("unexpected: \{err}")
          }
          assert_eq(client.state(), @client.ClientState::Connected)
          assert_eq(client.get_data("/x").data, None)
        },
      )
    },
  )
}

///|
async test "mismatched write response is an unknown outcome" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("request length")
      }
      ignore(conn.read_exactly(size))
      let reply = @buffer.Buffer()
      reply.write_int_be(16 + 68)
      reply.write_int_be(999)
      reply.write_int64_be(1L)
      reply.write_int_be(0)
      reply.write_bytes(stat_fixture(1))
      conn.write(reply.to_bytes())
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        try {
          ignore(client.set_data("/x", Some(b"v"), -1))
          fail("expected unknown outcome")
        } catch {
          @client.ClientError::OutcomeUnknown => ()
          err => fail("unexpected: \{err}")
        }
      })
    },
  )
}
