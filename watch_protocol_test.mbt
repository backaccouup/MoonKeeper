// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "watch reads set Jute watch flag and preserve their opcodes" {
  let exists = @moonkeeper.encode_watch_exists_request(7, "/中")
  let data = @moonkeeper.encode_watch_data_request(8, "/中")
  let children = @moonkeeper.encode_watch_children_request(9, "/中")
  assert_eq(exists[4:12].to_owned(), b"\x00\x00\x00\x07\x00\x00\x00\x03")
  assert_eq(data[4:12].to_owned(), b"\x00\x00\x00\x08\x00\x00\x00\x04")
  assert_eq(children[4:12].to_owned(), b"\x00\x00\x00\x09\x00\x00\x00\x0c")
  for wire in [exists, data, children] {
    assert_eq(wire[wire.length() - 1], b'\x01')
  }
}

///|
test "notification decodes node and session events distinctly" {
  let header = b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00"
  let node = @moonkeeper.decode_watch_notification(
    header + b"\x00\x00\x00\x03\x00\x00\x00\x03\x00\x00\x00\x04/\xe4\xb8\xad",
  )
  match node {
    @moonkeeper.WatchNotice::Node(event) => {
      assert_eq(event.kind, @moonkeeper.WatchEventType::NodeDataChanged)
      assert_eq(event.path, "/中")
    }
    _ => fail("expected node event")
  }
  let state = @moonkeeper.decode_watch_notification(
    header + b"\xff\xff\xff\xff\xff\xff\xff\x90\xff\xff\xff\xff",
  )
  assert_eq(state, @moonkeeper.WatchNotice::State(-112))
}

///|
test "notification rejects trailing bytes unknown types and invalid paths" {
  let header = b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00"
  for
    body in [
      b"\x00\x00\x00\x09\x00\x00\x00\x03\x00\x00\x00\x02/x", b"\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x01x",
      b"\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00\x02/xz",
    ] {
    try {
      ignore(@moonkeeper.decode_watch_notification(header + body))
      fail("invalid notice accepted")
    } catch {
      @moonkeeper.ProtocolError::_ => ()
      err => fail("unexpected: \{err}")
    }
  }
}
