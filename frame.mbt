// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// Incremental length-prefixed framing. Only the current partial frame is retained.
/// Completed frames include their four-byte prefix. Errors permanently seal the decoder.
pub struct FrameDecoder {
  priv buffer : @buffer.Buffer
  priv max_frame_size : Int32
  priv mut frame_length : Int32?
  priv mut closed : Bool
}

///|
/// `max_frame_size` limits payload bytes; zero-length frames are permitted.
pub fn FrameDecoder::new(
  max_frame_size~ : Int32 = 1048576,
) -> FrameDecoder raise ProtocolError {
  guard max_frame_size >= 0 && max_frame_size <= 2147483643 else {
    raise InvalidFrameLimit(max_frame_size)
  }
  {
    buffer: @buffer.Buffer(),
    max_frame_size,
    frame_length: None,
    closed: false,
  }
}

///|
pub fn FrameDecoder::feed(
  self : FrameDecoder,
  chunk : Bytes,
) -> Array[Bytes] raise ProtocolError {
  guard !self.closed else { raise DecoderClosed }
  let frames = []
  let mut offset = 0
  while offset < chunk.length() {
    if self.frame_length is None {
      let count = Int32::min(4 - self.buffer.length(), chunk.length() - offset)
      self.buffer.write_bytes(chunk[offset:offset + count])
      offset += count
      if self.buffer.length() < 4 {
        continue
      }
      let length = match self.buffer.to_bytes() {
        [i32be(length)] => length
        _ => abort("frame header invariant")
      }
      if length < 0 || length > self.max_frame_size {
        self.closed = true
        self.buffer.reset()
        if length < 0 {
          raise InvalidFrameLength(length)
        } else {
          raise FrameTooLarge(length)
        }
      }
      self.frame_length = Some(length + 4)
    }
    if self.frame_length is Some(length) {
      let count = Int32::min(
        length - self.buffer.length(),
        chunk.length() - offset,
      )
      self.buffer.write_bytes(chunk[offset:offset + count])
      offset += count
      if self.buffer.length() == length {
        frames.push(self.buffer.to_bytes())
        self.buffer.reset()
        self.frame_length = None
      }
    }
  }
  frames
}

///|
/// Seal the stream. A partial header or body is an error; a clean finish is idempotent.
pub fn FrameDecoder::finish(self : FrameDecoder) -> Unit raise ProtocolError {
  self.closed = true
  if !self.buffer.is_empty() {
    self.buffer.reset()
    raise TruncatedFrame
  }
}
