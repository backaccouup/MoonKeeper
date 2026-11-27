// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "multi check uses one request header, a subheader and an end marker" {
  let wire = @moonkeeper.encode_multi_request(7, [Check("/x", 3)])
  assert_eq(
    wire,
    b"\x00\x00\x00\x24\x00\x00\x00\x07\x00\x00\x00\x0e" +
    b"\x00\x00\x00\x0d\x00\xff\xff\xff\xff" +
    b"\x00\x00\x00\x02/x\x00\x00\x00\x03" +
    b"\xff\xff\xff\xff\x01\xff\xff\xff\xff",
  )
}

///|
test "multi distinguishes rolled back, failed and skipped operations" {
  let ops : Array[@moonkeeper.MultiOp] = [
    Delete("/a", -1),
    Check("/x", 4),
    SetData("/y", None, 0),
  ]
  let header = Bytes::make(16, b'\x00')
  let end = b"\xff\xff\xff\xff\x01\xff\xff\xff\xff"
  let error_op = b"\xff\xff\xff\xff\x00"
  let zero = b"\x00\x00\x00\x00"
  let unknown = b"\xff\xff\xfc\x19"
  let skipped = b"\xff\xff\xff\xfe"
  let body = error_op +
    zero +
    zero +
    error_op +
    unknown +
    unknown +
    error_op +
    skipped +
    skipped
  guard @moonkeeper.decode_multi_response(header + body + end, ops)
    is Aborted(index, results) else {
    fail("expected abort")
  }
  assert_eq(index, 1)
  assert_eq(results, [NotApplied(0), Failed(-999), NotApplied(-2)])
}

///|
test "multi rejects missing, extra, mismatched and truncated results" {
  let header = Bytes::make(16, b'\x00')
  let check = b"\x00\x00\x00\x0d\x00\x00\x00\x00\x00"
  let delete = b"\x00\x00\x00\x02\x00\x00\x00\x00\x00"
  let end = b"\xff\xff\xff\xff\x01\xff\xff\xff\xff"
  let ops : Array[@moonkeeper.MultiOp] = [Check("/x", -1)]
  guard @moonkeeper.decode_multi_response(header + check + end, ops)
    is Committed([Checked]) else {
    fail("expected committed check")
  }
  for
    body in [
      end,
      check + check + end,
      delete + end,
      check,
      check + end + b"x",
      check + end[:8].to_owned(),
      b"\xff\xff\xff\xff\x00\xff\xff\xff\x99\xff\xff\xff\x98" + end,
    ] {
    try {
      ignore(@moonkeeper.decode_multi_response(header + body, ops))
      fail("invalid multi reply accepted")
    } catch {
      @moonkeeper.ProtocolError::_ => ()
      err => raise err
    }
  }
}

///|
test "a top-level server error requires a complete header with no result records" {
  let ops : Array[@moonkeeper.MultiOp] = [Delete("/x", -1)]
  let header = b"\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x05\xff\xff\xff\x9a"
  try {
    ignore(@moonkeeper.decode_multi_response(header, ops))
    fail("expected server rejection")
  } catch {
    @moonkeeper.ProtocolError::ServerError(-102) => ()
    err => raise err
  }
  try {
    ignore(@moonkeeper.decode_multi_response(header + b"x", ops))
    fail("malformed reply accepted")
  } catch {
    @moonkeeper.ProtocolError::TrailingBytes(1) => ()
    err => raise err
  }
}
