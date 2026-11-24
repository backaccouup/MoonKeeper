// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "CRUD requests preserve null empty binary data and ACL" {
  let options = @moonkeeper.CreateOptions::new(
    @moonkeeper.CreateMode::Persistent,
    @moonkeeper.open_acl_unsafe(),
  )
  let null_request = @moonkeeper.encode_create_request(1, "/中", None, options)
  let empty_request = @moonkeeper.encode_create_request(
    2,
    "/中",
    Some(b""),
    options,
  )
  let binary_request = @moonkeeper.encode_create_request(
    3,
    "/中",
    Some(b"\x00\xff"),
    options,
  )
  assert_eq(null_request[4:12].to_owned(), b"\x00\x00\x00\x01\x00\x00\x00\x01")
  assert_eq(null_request[12:20].to_owned(), b"\x00\x00\x00\x04/\xe4\xb8\xad")
  assert_eq(null_request[20:24].to_owned(), b"\xff\xff\xff\xff")
  assert_eq(empty_request[20:24].to_owned(), b"\x00\x00\x00\x00")
  assert_eq(binary_request[20:26].to_owned(), b"\x00\x00\x00\x02\x00\xff")
  assert_eq(null_request[24:28].to_owned(), b"\x00\x00\x00\x01")
  assert_eq(null_request[28:32].to_owned(), b"\x00\x00\x00\x1f")
  assert_eq(null_request[32:41].to_owned(), b"\x00\x00\x00\x05world")
  assert_eq(null_request[41:51].to_owned(), b"\x00\x00\x00\x06anyone")
  assert_eq(null_request[51:55].to_owned(), b"\x00\x00\x00\x00")
}

///|
test "get set delete wire opcodes and version boundary" {
  assert_eq(
    @moonkeeper.encode_get_data_request(7, "/x")[4:12].to_owned(),
    b"\x00\x00\x00\x07\x00\x00\x00\x04",
  )
  assert_eq(
    @moonkeeper.encode_set_data_request(8, "/x", Some(b"a"), -1)[4:12].to_owned(),
    b"\x00\x00\x00\x08\x00\x00\x00\x05",
  )
  assert_eq(
    @moonkeeper.encode_delete_request(9, "/x", 0)[4:12].to_owned(),
    b"\x00\x00\x00\x09\x00\x00\x00\x02",
  )
  for path in ["", "relative", "/a//b", "/a/./b", "/a/../b", "/x\u0000y", "/"] {
    try {
      ignore(@moonkeeper.encode_delete_request(1, path, -1))
      fail("invalid deletion path accepted")
    } catch {
      @moonkeeper.ProtocolError::InvalidPath(_) => ()
      err => fail("unexpected: \{err}")
    }
  }
  try {
    ignore(@moonkeeper.encode_set_data_request(1, "/x", None, -2))
    fail("invalid version accepted")
  } catch {
    @moonkeeper.ProtocolError::InvalidVersion(-2) => ()
    err => fail("unexpected: \{err}")
  }
}

///|
test "CRUD replies return actual path data stat and server errors" {
  let header = b"\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00"
  assert_eq(
    @moonkeeper.decode_create_response(header + b"\x00\x00\x00\x02/x"),
    "/x",
  )
  let stat = b"\x00\x00\x00\x00\x00\x00\x00\x01" +
    b"\x00\x00\x00\x00\x00\x00\x00\x02" +
    b"\x00\x00\x00\x00\x00\x00\x00\x03" +
    b"\x00\x00\x00\x00\x00\x00\x00\x04" +
    b"\x00\x00\x00\x05\x00\x00\x00\x06\x00\x00\x00\x07" +
    b"\x00\x00\x00\x00\x00\x00\x00\x08" +
    b"\x00\x00\x00\x09\x00\x00\x00\x0a" +
    b"\x00\x00\x00\x00\x00\x00\x00\x0b"
  let result = @moonkeeper.decode_get_data_response(
    header + b"\x00\x00\x00\x02\x00\xff" + stat,
  )
  assert_eq(result.data, Some(b"\x00\xff"))
  assert_eq(result.stat.version, 5)
  assert_eq(@moonkeeper.decode_set_data_response(header + stat).pzxid, 11L)
  @moonkeeper.decode_delete_response(header)
  try {
    ignore(
      @moonkeeper.decode_create_response(
        b"\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\x92",
      ),
    )
    fail("expected NodeExists")
  } catch {
    @moonkeeper.ProtocolError::ServerError(-110) => ()
    err => fail("unexpected: \{err}")
  }
}
