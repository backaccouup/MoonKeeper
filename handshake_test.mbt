// Copyright 2026 Mr-Shi123
// SPDX-License-Identifier: Apache-2.0

// Wire fixtures are hand-authored from Apache ZooKeeper 3.9.3's
// zookeeper.jute schema, not produced by the codec under test.

///|
fn response_fixture() -> Bytes {
  b"\x00\x00\x00\x25" + // payload length: 37
  b"\x00\x00\x00\x00" + // protocol version
  b"\x00\x00\x75\x30" + // negotiated timeout: 30000 ms
  b"\x01\x02\x03\x04\x05\x06\x07\x08" + // session ID, larger than 2^53
  b"\x00\x00\x00\x10" + // password length: 16
  b"0123456789abcdef" +
  b"\x00" // readOnly
}

///|
test "new session request matches the ZooKeeper wire layout" {
  let expected = b"\x00\x00\x00\x2d" +
    b"\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x75\x30" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x10" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00"
  assert_eq(@moonkeeper.encode_connect_request(30000), expected)
}

///|
test "request can opt into read-only servers" {
  let frame = @moonkeeper.encode_connect_request(1, read_only=true)
  assert_eq(frame.length(), 49)
  assert_eq(frame[16:20].to_owned(), b"\x00\x00\x00\x01")
  assert_eq(frame[48], b'\x01')
}

///|
test "request rejects nonpositive session timeouts" {
  for timeout in [0, -1] {
    try {
      ignore(@moonkeeper.encode_connect_request(timeout))
      fail("expected InvalidTimeout")
    } catch {
      @moonkeeper.ProtocolError::InvalidTimeout(value) =>
        assert_eq(value, timeout)
      error => fail("unexpected error: \{error}")
    }
  }
}

///|
test "response preserves every field including a 64-bit session ID" {
  let response = @moonkeeper.decode_connect_response(response_fixture())
  assert_eq(response.protocol_version, 0)
  assert_eq(response.session_timeout_ms, 30000)
  assert_eq(response.session_id, 0x0102030405060708L)
  assert_eq(response.password, Some(b"0123456789abcdef"))
  assert_eq(response.read_only, false)
}

///|
test "response reads signed integers and Java boolean semantics" {
  let frame = b"\x00\x00\x00\x15" +
    b"\xff\xff\xff\xff" + // preserve an unknown protocol version
    b"\x00\x00\x00\x01" +
    b"\xff\xff\xff\xff\xff\xff\xff\xff" +
    b"\x00\x00\x00\x00" + // empty buffer, distinct from null
    b"\xff" // Java DataInput.readBoolean treats any nonzero byte as true
  let response = @moonkeeper.decode_connect_response(frame)
  assert_eq(response.protocol_version, -1)
  assert_eq(response.session_id, -1L)
  assert_eq(response.password, Some(b""))
  assert_eq(response.read_only, true)
}

///|
test "legacy response may omit the read-only byte" {
  let modern = response_fixture()
  let legacy = b"\x00\x00\x00\x24" + modern[4:40].to_owned()
  let response = @moonkeeper.decode_connect_response(legacy)
  assert_eq(response.password, Some(b"0123456789abcdef"))
  assert_eq(response.read_only, false)
}

///|
test "rejected session response retains zero timeout and null password" {
  let frame = b"\x00\x00\x00\x15" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\xff\xff\xff\xff\x00"
  let response = @moonkeeper.decode_connect_response(frame)
  assert_eq(response.session_timeout_ms, 0)
  assert_eq(response.session_id, 0L)
  assert_eq(response.password, None)
}

///|
test "every proper prefix of a response is rejected without panicking" {
  let frame = response_fixture()
  for length in 0..<frame.length() {
    try {
      ignore(@moonkeeper.decode_connect_response(frame[:length].to_owned()))
      fail("accepted a truncated frame of length \{length}")
    } catch {
      @moonkeeper.ProtocolError::TruncatedFrame => assert_true(length < 4)
      @moonkeeper.ProtocolError::FrameLengthMismatch(_, _) =>
        assert_true(length >= 4)
      error => fail("unexpected error: \{error}")
    }
  }
}

///|
test "negative frame length is rejected" {
  try {
    ignore(@moonkeeper.decode_connect_response(b"\xff\xff\xff\xff"))
    fail("expected InvalidFrameLength")
  } catch {
    @moonkeeper.ProtocolError::InvalidFrameLength(-1) => ()
    error => fail("unexpected error: \{error}")
  }
}

///|
test "oversized length is rejected before waiting for its payload" {
  for frame in [b"\x00\x10\x00\x01", b"\x7f\xff\xff\xff"] {
    try {
      ignore(@moonkeeper.decode_connect_response(frame))
      fail("expected FrameTooLarge")
    } catch {
      @moonkeeper.ProtocolError::FrameTooLarge(_) => ()
      error => fail("unexpected error: \{error}")
    }
  }
}

///|
test "decoder consumes exactly one frame" {
  let frame = response_fixture() + b"\x00"
  try {
    ignore(@moonkeeper.decode_connect_response(frame))
    fail("expected FrameLengthMismatch")
  } catch {
    @moonkeeper.ProtocolError::FrameLengthMismatch(37, 38) => ()
    error => fail("unexpected error: \{error}")
  }
}

///|
test "complete frame must contain all fixed response fields" {
  try {
    ignore(@moonkeeper.decode_connect_response(b"\x00\x00\x00\x01\x00"))
    fail("expected TruncatedPayload")
  } catch {
    @moonkeeper.ProtocolError::TruncatedPayload => ()
    error => fail("unexpected error: \{error}")
  }
}

///|
test "password length below minus one is invalid" {
  let frame = response_fixture()
  let invalid = frame[:20].to_owned() +
    b"\xff\xff\xff\xfe" +
    frame[24:].to_owned()
  try {
    ignore(@moonkeeper.decode_connect_response(invalid))
    fail("expected InvalidBufferLength")
  } catch {
    @moonkeeper.ProtocolError::InvalidBufferLength(-2) => ()
    error => fail("unexpected error: \{error}")
  }
}

///|
test "password length cannot exceed the remaining bytes" {
  let frame = response_fixture()
  let invalid = frame[:20].to_owned() +
    b"\x7f\xff\xff\xff" +
    frame[24:].to_owned()
  try {
    ignore(@moonkeeper.decode_connect_response(invalid))
    fail("expected TruncatedPayload")
  } catch {
    @moonkeeper.ProtocolError::TruncatedPayload => ()
    error => fail("unexpected error: \{error}")
  }
}

///|
test "extra bytes within the response payload are rejected" {
  let frame = response_fixture()
  let invalid = b"\x00\x00\x00\x26" + frame[4:].to_owned() + b"\x00"
  try {
    ignore(@moonkeeper.decode_connect_response(invalid))
    fail("expected TrailingBytes")
  } catch {
    @moonkeeper.ProtocolError::TrailingBytes(2) => ()
    error => fail("unexpected error: \{error}")
  }
}
