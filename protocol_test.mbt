// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "exists request carries xid and Jute path" {
  let wire = @moonkeeper.encode_exists_request(7, "/hello")
  assert_eq(
    wire, b"\x00\x00\x00\x13\x00\x00\x00\x07\x00\x00\x00\x03\x00\x00\x00\x06/hello\x00",
  )
}

///|
test "reply header preserves 64 bit zxid" {
  let payload = b"\x00\x00\x00\x07\x00\x20\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00"
  let header = @moonkeeper.decode_reply_header(payload)
  assert_eq(header.xid, 7)
  assert_eq(header.zxid, 9007199254740993L)
  assert_eq(header.err, 0)
}

///|
test "exists response distinguishes no node and malformed stat" {
  let missing = b"\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\x9b"
  assert_eq(@moonkeeper.decode_exists_response(missing), None)
  try {
    ignore(
      @moonkeeper.decode_exists_response(
        b"\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
      ),
    )
    fail("expected truncated stat")
  } catch {
    @moonkeeper.ProtocolError::_ => ()
    err => fail("unexpected: \{err}")
  }
}

///|
test "complete stat retains signed versions and all 64 bit fields" {
  let payload = b"\x00\x00\x00\x07\x00\x20\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00" +
    b"\x00\x20\x00\x00\x00\x00\x00\x02" +
    b"\x00\x20\x00\x00\x00\x00\x00\x03" +
    b"\x00\x00\x00\x00\x00\x00\x00\x04" +
    b"\x00\x00\x00\x00\x00\x00\x00\x05" +
    b"\x00\x00\x00\x06\x00\x00\x00\x07\x00\x00\x00\x08" +
    b"\x00\x20\x00\x00\x00\x00\x00\x09" +
    b"\x00\x00\x00\x0a\x00\x00\x00\x0b" +
    b"\x00\x20\x00\x00\x00\x00\x00\x0c"
  let stat = @moonkeeper.decode_exists_response(payload).unwrap()
  assert_eq(stat.czxid, 9007199254740994L)
  assert_eq(stat.mzxid, 9007199254740995L)
  assert_eq(stat.ctime, 4L)
  assert_eq(stat.mtime, 5L)
  assert_eq(stat.version, 6)
  assert_eq(stat.cversion, 7)
  assert_eq(stat.aversion, 8)
  assert_eq(stat.ephemeral_owner, 9007199254741001L)
  assert_eq(stat.data_length, 10)
  assert_eq(stat.num_children, 11)
  assert_eq(stat.pzxid, 9007199254741004L)
}

///|
test "paths are validated before encoding" {
  for path in ["", "relative", "/a/", "/a//b", "/a/./b", "/a/../b", "/x\u0000y"] {
    try {
      ignore(@moonkeeper.encode_exists_request(1, path))
      fail("invalid path accepted")
    } catch {
      @moonkeeper.ProtocolError::InvalidPath(_) => ()
      err => fail("unexpected: \{err}")
    }
  }
  assert_true(@moonkeeper.encode_exists_request(1, "/中文").length() > 16)
}
