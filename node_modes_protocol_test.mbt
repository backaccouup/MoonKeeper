// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "create flags and sequential prefix validation" {
  let acl = @moonkeeper.open_acl_unsafe()
  for
    (mode, flag) in [
      (@moonkeeper.CreateMode::Persistent, 0),
      (@moonkeeper.CreateMode::Ephemeral, 1),
      (@moonkeeper.CreateMode::PersistentSequential, 2),
      (@moonkeeper.CreateMode::EphemeralSequential, 3),
    ] {
    let path = if flag >= 2 { "/parent/" } else { "/parent/node" }
    let wire = @moonkeeper.encode_create_request(
      7,
      path,
      None,
      @moonkeeper.CreateOptions::new(mode, acl),
    )
    assert_eq(wire[wire.length() - 4:].to_owned(), mode_int_wire(flag))
  }
  ignore(
    @moonkeeper.encode_create_request(
      7,
      "/",
      None,
      @moonkeeper.CreateOptions::new(
        @moonkeeper.CreateMode::PersistentSequential,
        acl,
      ),
    ),
  )
  for path in ["/parent//", "relative/", "/parent/./"] {
    try {
      ignore(
        @moonkeeper.encode_create_request(
          7,
          path,
          None,
          @moonkeeper.CreateOptions::new(
            @moonkeeper.CreateMode::EphemeralSequential,
            acl,
          ),
        ),
      )
      fail("invalid sequential prefix accepted")
    } catch {
      @moonkeeper.ProtocolError::InvalidPath(_) => ()
      err => fail("unexpected: \{err}")
    }
  }
}

///|
fn mode_int_wire(value : Int32) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(value)
  out.to_bytes()
}

///|
fn child_stat_fixture() -> Bytes {
  let out = @buffer.Buffer()
  for value in [1L, 2L, 3L, 4L] {
    out.write_int64_be(value)
  }
  for value in [5, 6, 7] {
    out.write_int_be(value)
  }
  out.write_int64_be(8L)
  out.write_int_be(9)
  out.write_int_be(10)
  out.write_int64_be(9007199254740993L)
  out.to_bytes()
}

///|
test "getChildren replies preserve order and getChildren2 complete Stat" {
  let ordinary = @moonkeeper.encode_get_children_request(7, "/parent")
  let with_stat = @moonkeeper.encode_get_children_with_stat_request(
    8, "/parent",
  )
  assert_eq(ordinary[4:12].to_owned(), mode_int_wire(7) + mode_int_wire(8))
  assert_eq(with_stat[4:12].to_owned(), mode_int_wire(8) + mode_int_wire(12))
  let header = b"\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00"
  let empty = header + mode_int_wire(0)
  assert_eq(@moonkeeper.decode_get_children_response(empty).length(), 0)
  let names = header +
    mode_int_wire(2) +
    mode_int_wire(1) +
    b"b" +
    mode_int_wire(3) +
    b"\xe4\xb8\xad"
  assert_eq(@moonkeeper.decode_get_children_response(names), ["b", "中"])
  let result = @moonkeeper.decode_get_children_with_stat_response(
    names + child_stat_fixture(),
  )
  assert_eq(result.children, ["b", "中"])
  assert_eq(result.stat.czxid, 1L)
  assert_eq(result.stat.mzxid, 2L)
  assert_eq(result.stat.ctime, 3L)
  assert_eq(result.stat.mtime, 4L)
  assert_eq(result.stat.version, 5)
  assert_eq(result.stat.cversion, 6)
  assert_eq(result.stat.aversion, 7)
  assert_eq(result.stat.ephemeral_owner, 8L)
  assert_eq(result.stat.data_length, 9)
  assert_eq(result.stat.num_children, 10)
  assert_eq(result.stat.pzxid, 9007199254740993L)
}

///|
test "malformed child vector is rejected before allocation" {
  let header = b"\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00"
  for
    body in [
      mode_int_wire(-1),
      mode_int_wire(1000000),
      mode_int_wire(1) + mode_int_wire(9) + b"a",
    ] {
    try {
      ignore(@moonkeeper.decode_get_children_response(header + body))
      fail("malformed children accepted")
    } catch {
      @moonkeeper.ProtocolError::_ => ()
      err => fail("unexpected: \{err}")
    }
  }
}
