// Copyright 2026 Mr-Shi123
// SPDX-License-Identifier: Apache-2.0

///|
/// Malformed wire data or an invalid new-session request.
/// Lengths in these errors are byte counts, excluding the four-byte frame prefix.
#derive(Debug)
pub suberror ProtocolError {
  InvalidTimeout(Int32)
  TruncatedFrame
  InvalidFrameLength(Int32)
  FrameTooLarge(Int32)
  FrameLengthMismatch(Int32, Int32)
  TruncatedPayload
  InvalidBufferLength(Int32)
  TrailingBytes(Int32)
  InvalidFrameLimit(Int32)
  DecoderClosed
  InvalidPath(String)
  UnexpectedResponse(Int32)
  ServerError(Int32)
}

///|
pub extend ProtocolError with @debug.Debug::{to_repr}

///|
/// Decoded wire fields, not proof that a session was established.
/// A nonpositive timeout signals session rejection at the client layer.
/// The password is a session credential; do not print it in application logs.
pub struct ConnectResponse {
  protocol_version : Int32
  session_timeout_ms : Int32
  session_id : Int64
  password : Bytes?
  read_only : Bool
}

///|
/// Encode a new-session ConnectRequest, including its four-byte length prefix.
/// Uses protocol version 0, zero last-zxid/session ID, and a 16-byte zero password.
/// `read_only` allows a connection to a read-only server; it defaults to false.
/// Resuming an existing session is not supported by this initial API.
pub fn encode_connect_request(
  session_timeout_ms : Int32,
  read_only~ : Bool = false,
) -> Bytes raise ProtocolError {
  guard session_timeout_ms > 0 else { raise InvalidTimeout(session_timeout_ms) }
  let out = @buffer.Buffer()
  out.write_int_be(45)
  out.write_int_be(0)
  out.write_int64_be(0L)
  out.write_int_be(session_timeout_ms)
  out.write_int64_be(0L)
  out.write_int_be(16)
  out.write_bytes(Bytes::make(16, b'\x00'))
  out.write_byte(if read_only { b'\x01' } else { b'\x00' })
  out.to_bytes()
}

///|
/// Decode exactly one complete, length-prefixed ConnectResponse.
/// Payloads are limited to 1 MiB by this library, independently of server settings.
/// Null and empty passwords remain distinct. The legacy omitted `readOnly` byte
/// defaults to false; otherwise Java's nonzero-is-true boolean rule is used.
/// Protocol version and timeout are preserved for the future client to validate.
/// This function does not buffer partial TCP reads or consume concatenated frames.
pub fn decode_connect_response(
  frame : Bytes,
) -> ConnectResponse raise ProtocolError {
  guard frame is [i32be(length), .. payload] else { raise TruncatedFrame }
  guard length >= 0 else { raise InvalidFrameLength(length) }
  guard length <= 1048576 else { raise FrameTooLarge(length) }
  guard length == payload.length() else {
    raise FrameLengthMismatch(length, payload.length())
  }
  guard payload
    is [
      i32be(protocol_version),
      i32be(session_timeout_ms),
      i64be(session_id),
      i32be(buffer_length),
      .. rest,
    ] else {
    raise TruncatedPayload
  }
  guard buffer_length >= -1 else { raise InvalidBufferLength(buffer_length) }
  let password_length = if buffer_length == -1 { 0 } else { buffer_length }
  // Check against available bytes before slicing or allocating a password.
  guard password_length <= rest.length() else { raise TruncatedPayload }
  let trailing_length = rest.length() - password_length
  let read_only = match trailing_length {
    0 => false
    1 => rest[password_length] != b'\x00'
    _ => raise TrailingBytes(trailing_length)
  }
  let password = if buffer_length == -1 {
    None
  } else {
    Some(rest[:password_length].to_owned())
  }
  { protocol_version, session_timeout_ms, session_id, password, read_only, }
}
