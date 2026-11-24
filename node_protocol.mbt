// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub fn encode_exists_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  guard xid > 0 else { raise UnexpectedResponse(xid) }
  validate_path(path)
  let path_bytes = @utf8.encode(path)
  let out = @buffer.Buffer()
  out.write_int_be(13 + path_bytes.length())
  out.write_int_be(xid)
  out.write_int_be(3)
  out.write_int_be(path_bytes.length())
  out.write_bytes(path_bytes)
  out.write_byte(b'\x00')
  out.to_bytes()
}

///|
pub fn decode_exists_response(payload : Bytes) -> Stat? raise ProtocolError {
  let reply = decode_reply_header(payload)
  guard payload.length() >= 16 else { raise TruncatedPayload }
  if reply.err == -101 {
    guard payload.length() == 16 else {
      raise TrailingBytes(payload.length() - 16)
    }
    return None
  }
  guard reply.err == 0 else { raise ServerError(reply.err) }
  guard payload
    is [
      i32be(_),
      i64be(_),
      i32be(_),
      i64be(czxid),
      i64be(mzxid),
      i64be(ctime),
      i64be(mtime),
      i32be(version),
      i32be(cversion),
      i32be(aversion),
      i64be(ephemeral_owner),
      i32be(data_length),
      i32be(num_children),
      i64be(pzxid),
    ] else {
    raise TruncatedPayload
  }
  Some({
    czxid,
    mzxid,
    ctime,
    mtime,
    version,
    cversion,
    aversion,
    ephemeral_owner,
    data_length,
    num_children,
    pzxid,
  })
}
