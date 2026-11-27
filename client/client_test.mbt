// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn fixture() -> Bytes {
  b"\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x75\x30" +
  b"\x01\x02\x03\x04\x05\x06\x07\x08\x00\x00\x00\x10" +
  b"0123456789abcdef\x00"
}

///|
async fn[T] with_peer(
  peer : async (@socket.Tcp) -> Unit,
  body : async (@client.Endpoint) -> T,
) -> T {
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
      defer server.close()
      group.spawn_bg(() => {
        let (conn, _) = server.accept()
        defer conn.close()
        peer(conn)
      })
      body(@client.Endpoint::new("127.0.0.1", port=server.addr.port()))
    })
  })
}

///|
async test "real TCP sends full request and accepts a bytewise handshake then closes" {
  let result = with_peer(
    conn => {
      let request = conn.read_exactly(49)
      assert_eq(
        request[:20].to_owned(),
        b"\x00\x00\x00\x2d\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x75\x30",
      )
      for byte in fixture() {
        conn.write(Bytes::make(1, byte))
        @async.sleep(1)
      }
      assert_eq(conn.read_exactly(12), @moonkeeper.encode_close_session(1))
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        let info = client.session_info()
        assert_eq(info.session_id, 0x0102030405060708L)
        assert_eq(info.session_timeout_ms, 30000)
        assert_eq(info.read_only, false)
        42
      })
    },
  )
  assert_eq(result, 42)
}

///|
async test "EOF during a response reports truncated protocol and closes" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture()[:17])
    },
    endpoint => {
      try {
        @client.with_client(@client.ClientOptions::new(endpoint), _ => {
          fail("must not enter callback")
        })
        fail("expected failure")
      } catch {
        @client.ClientError::Protocol(@moonkeeper.ProtocolError::TruncatedFrame) =>
          ()
        error => fail("unexpected: \{error}")
      }
    },
  )
}

///|
async test "silent peer hits handshake deadline and observes socket closure" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      try {
        @client.with_client(
          @client.ClientOptions::new(endpoint, request_timeout_ms=50),
          _ => fail("must not connect"),
        )
        fail("expected timeout")
      } catch {
        @client.ClientError::HandshakeTimeout => ()
        error => fail("unexpected: \{error}")
      }
    },
  )
}

///|
suberror CallbackFailed

///|
async test "callback errors propagate unchanged and close the connection" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      assert_eq(conn.read_exactly(12), @moonkeeper.encode_close_session(1))
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      try {
        @client.with_client(@client.ClientOptions::new(endpoint), _ => {
          raise CallbackFailed
        })
        fail("expected callback failure")
      } catch {
        CallbackFailed => ()
        error => fail("unexpected: \{error}")
      }
    },
  )
}

///|
async test "external cancellation closes a connected socket" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      assert_eq(conn.read_some(), None)
    },
    endpoint => {
      let result = @async.with_timeout_opt(100, () => {
        @client.with_client(@client.ClientOptions::new(endpoint), _ => {
          @async.sleep(2000)
        })
      })
      assert_eq(result, None)
    },
  )
}

///|
async test "negotiation rejects refused unsupported and invalid sessions" {
  let cases = [
    (
      b"\x00\x00\x00\x15\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00",
      "rejected",
    ),
    (fixture()[:7].to_owned() + b"\x01" + fixture()[8:].to_owned(), "version"),
    (
      fixture()[:12].to_owned() +
      Bytes::make(8, b'\x00') +
      fixture()[20:].to_owned(),
      "id",
    ),
    (fixture()[:40].to_owned() + b"\x01", "readonly"),
  ]
  for (wire, expected) in cases {
    with_peer(
      conn => {
        ignore(conn.read_exactly(49))
        conn.write(wire)
        assert_eq(conn.read_some(), None)
      },
      endpoint => {
        let actual = try {
          @client.with_client(@client.ClientOptions::new(endpoint), _ => ())
          "accepted"
        } catch {
          @client.ClientError::SessionRejected => "rejected"
          @client.ClientError::UnsupportedProtocol(_) => "version"
          @client.ClientError::InvalidSession(_) => "id"
          @client.ClientError::ReadOnlyNotAllowed => "readonly"
          error => fail("unexpected: \{error}")
        }
        assert_eq(actual, expected)
      },
    )
  }
}

///|
async test "refused TCP connection and invalid options are distinct" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  server.close()
  try {
    @client.with_client(
      @client.ClientOptions::new(@client.Endpoint::new("127.0.0.1", port~)),
      _ => (),
    )
    fail("expected connection failure")
  } catch {
    @client.ClientError::Transport(_) => ()
    error => fail("unexpected: \{error}")
  }
  try {
    @client.with_client(
      @client.ClientOptions::new(@client.Endpoint::new("", port=0)),
      _ => (),
    )
    fail("expected invalid options")
  } catch {
    @client.ClientError::InvalidOptions(_) => ()
    error => fail("unexpected: \{error}")
  }
}

///|
async test "endpoint rejects embedded NUL before native hostname resolution" {
  try {
    @client.with_client(
      @client.ClientOptions::new(
        @client.Endpoint::new("127.0.0.1\u0000ignored.invalid", port=1),
      ),
      _ => (),
    )
    fail("expected invalid endpoint")
  } catch {
    @client.ClientError::InvalidOptions(_) => ()
    error => fail("unexpected: \{error}")
  }
}

///|
async test "handshake consumes exactly one frame regardless of following bytes" {
  for following in [b"\x00\x00", b"\x00\x00\x00\x02ok"] {
    with_peer(
      conn => {
        ignore(conn.read_exactly(49))
        conn.write(fixture() + following)
      },
      endpoint => {
        @client.with_client(@client.ClientOptions::new(endpoint), client => {
          assert_eq(client.session_info().session_id, 0x0102030405060708L)
        })
      },
    )
  }
}
