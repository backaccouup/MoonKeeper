// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "digest AuthPacket uses reserved xid, zero type and raw credential bytes" {
  let wire = @moonkeeper.encode_auth_request("digest", b"u:p:w")
  assert_true(
    wire ==
    b"\x00\x00\x00\x1f\xff\xff\xff\xfc\x00\x00\x00\x64" +
    b"\x00\x00\x00\x00\x00\x00\x00\x06digest\x00\x00\x00\x05u:p:w",
  )
  let reply = b"\xff\xff\xff\xfc" + Bytes::make(8, b'\x00')
  @moonkeeper.decode_auth_response(reply + mode_int_wire(0))
  try {
    @moonkeeper.decode_auth_response(reply + mode_int_wire(-321))
    fail("expected server rejection")
  } catch {
    @moonkeeper.ProtocolError::ServerError(-321) => ()
    e => fail("unexpected error \{e}")
  }
  for
    payload in [
      reply,
      reply + mode_int_wire(0) + b"x",
      Bytes::make(16, b'\x00'),
    ] {
    try {
      @moonkeeper.decode_auth_response(payload)
      fail("malformed reply accepted")
    } catch {
      @moonkeeper.ProtocolError::_ => ()
      e => fail("unexpected error \{e}")
    }
  }
}

///|
test "auth diagnostics omit malformed credential and unsupported scheme values" {
  for
    (scheme, data) in [
      ("accidental-password", b"u:p"),
      ("digest", b"accidental-password"),
    ] {
    try {
      ignore(@moonkeeper.encode_auth_request(scheme, data))
      fail("invalid auth input accepted")
    } catch {
      @moonkeeper.ProtocolError::_ as e =>
        assert_false(@debug.to_string(e).contains("accidental-password"))
      _ => fail("unexpected auth error")
    }
  }
}

///|
test "getACL and setACL use ACL version, vector order and permission mask" {
  let all = @moonkeeper.PERM_READ |
    @moonkeeper.PERM_WRITE |
    @moonkeeper.PERM_CREATE |
    @moonkeeper.PERM_DELETE |
    @moonkeeper.PERM_ADMIN
  assert_eq(all, @moonkeeper.PERM_ALL)
  assert_eq(all, 31)
  let identity : @moonkeeper.Acl = {
    permissions: @moonkeeper.PERM_READ | @moonkeeper.PERM_WRITE,
    scheme: "world",
    id: "anyone",
  }
  let acls = @moonkeeper.creator_acl()
  acls.push(identity)
  let vector = mode_int_wire(2) +
    mode_int_wire(31) +
    mode_int_wire(4) +
    b"auth" +
    mode_int_wire(0) +
    mode_int_wire(3) +
    mode_int_wire(5) +
    b"world" +
    mode_int_wire(6) +
    b"anyone"
  let path = mode_int_wire(2) + b"/x"
  let req = @moonkeeper.encode_get_acl_request(3, "/x")
  assert_eq(req[4:].to_owned(), mode_int_wire(3) + mode_int_wire(6) + path)
  let changed = @moonkeeper.encode_set_acl_request(7, "/x", acls, 13)
  assert_eq(
    changed[4:].to_owned(),
    mode_int_wire(7) + mode_int_wire(7) + path + vector + mode_int_wire(13),
  )
  let header = mode_int_wire(3) + Bytes::make(12, b'\x00')
  let result = @moonkeeper.decode_get_acl_response(
    header + vector + child_stat_fixture(),
  )
  assert_eq(result.acl, acls)
  assert_eq(
    result.stat,
    @moonkeeper.decode_set_acl_response(header + child_stat_fixture()),
  )
  try {
    ignore(
      @moonkeeper.decode_set_acl_response(
        header[:12].to_owned() + mode_int_wire(-103),
      ),
    )
    fail("expected BadVersion")
  } catch {
    @moonkeeper.ProtocolError::ServerError(-103) => ()
    e => fail("unexpected error \{e}")
  }
}

///|
test "ACL decoding rejects impossible vector and string lengths" {
  let header = Bytes::make(16, b'\x00')
  for
    vector in [
      mode_int_wire(-1),
      mode_int_wire(2147483647),
      mode_int_wire(1),
      mode_int_wire(1) + mode_int_wire(1) + mode_int_wire(-1),
      mode_int_wire(1) + mode_int_wire(1) + mode_int_wire(2147483647),
      mode_int_wire(1) +
      mode_int_wire(1) +
      mode_int_wire(1) +
      b"\xff" +
      mode_int_wire(0),
      mode_int_wire(0) + b"x",
    ] {
    try {
      ignore(
        @moonkeeper.decode_get_acl_response(
          header + vector + child_stat_fixture(),
        ),
      )
      fail("malformed vector accepted")
    } catch {
      @moonkeeper.ProtocolError::_ => ()
      e => fail("unexpected error \{e}")
    }
  }
}

///|
test "auth checks the complete frame length before encoding the credential" {
  let one_over = b"u:" + Bytes::make(1048576 - 27, b'x')
  try {
    ignore(@moonkeeper.encode_auth_request("digest", one_over))
    fail("oversized digest frame accepted")
  } catch {
    @moonkeeper.ProtocolError::FrameTooLarge(1048577) => ()
    _ => fail("incorrect auth frame length")
  }
}
