// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "frames survive every split point and bytewise input" {
  let wire = b"\x00\x00\x00\x03abc"
  for split = 0; split <= wire.length(); split = split + 1 {
    let decoder = @moonkeeper.FrameDecoder::new()
    let frames = decoder.feed(wire[:split].to_owned())
    frames.append(decoder.feed(wire[split:].to_owned()))
    assert_eq(frames, [wire])
    decoder.finish()
  }
  let decoder = @moonkeeper.FrameDecoder::new()
  let frames = []
  for byte in wire {
    frames.append(decoder.feed(Bytes::make(1, byte)))
  }
  assert_eq(frames, [wire])
  decoder.finish()
}

///|
test "coalesced frames preserve headers including an empty payload" {
  let decoder = @moonkeeper.FrameDecoder::new()
  let first = b"\x00\x00\x00\x00"
  let second = b"\x00\x00\x00\x02hi"
  assert_eq(decoder.feed(first + second + second[:3].to_owned()), [
    first, second,
  ])
  assert_eq(decoder.feed(second[3:].to_owned()), [second])
  decoder.finish()
}

///|
test "EOF rejects every incomplete prefix and body" {
  let wire = b"\x00\x00\x00\x03abc"
  for end = 1; end < wire.length(); end = end + 1 {
    let decoder = @moonkeeper.FrameDecoder::new()
    assert_eq(decoder.feed(wire[:end].to_owned()), [])
    try {
      decoder.finish()
      fail("expected truncated frame")
    } catch {
      @moonkeeper.ProtocolError::TruncatedFrame => ()
      error => fail("unexpected: \{error}")
    }
  }
  @moonkeeper.FrameDecoder::new().finish()
}

///|
test "length validation precedes receiving or allocating the body" {
  for wire in [b"\xff\xff\xff\xff", b"\x00\x10\x00\x01", b"\x7f\xff\xff\xff"] {
    let decoder = @moonkeeper.FrameDecoder::new()
    try {
      ignore(decoder.feed(wire))
      fail("expected invalid length")
    } catch {
      @moonkeeper.ProtocolError::InvalidFrameLength(-1) => ()
      @moonkeeper.ProtocolError::FrameTooLarge(_) => ()
      error => fail("unexpected: \{error}")
    }
    // A framing error is terminal; do not reinterpret later bytes as a header.
    try {
      ignore(decoder.feed(b"\x00\x00\x00\x00"))
      fail("expected terminal decoder")
    } catch {
      @moonkeeper.ProtocolError::DecoderClosed => ()
      error => fail("unexpected: \{error}")
    }
  }
}

///|
test "custom limit is inclusive and finish seals the decoder" {
  let decoder = @moonkeeper.FrameDecoder::new(max_frame_size=3)
  assert_eq(decoder.feed(b"\x00\x00\x00\x03abc"), [b"\x00\x00\x00\x03abc"])
  decoder.finish()
  decoder.finish()
  try {
    ignore(decoder.feed(b""))
    fail("expected closed decoder")
  } catch {
    @moonkeeper.ProtocolError::DecoderClosed => ()
    error => fail("unexpected: \{error}")
  }
  try {
    ignore(
      @moonkeeper.FrameDecoder::new(max_frame_size=3).feed(b"\x00\x00\x00\x04"),
    )
    fail("expected frame too large")
  } catch {
    @moonkeeper.ProtocolError::FrameTooLarge(4) => ()
    error => fail("unexpected: \{error}")
  }
  for size in [-1, 2147483647] {
    try {
      ignore(@moonkeeper.FrameDecoder::new(max_frame_size=size))
      fail("expected invalid frame limit")
    } catch {
      @moonkeeper.ProtocolError::InvalidFrameLimit(_) => ()
      error => fail("unexpected: \{error}")
    }
  }
}
