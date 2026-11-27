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
  out.write_bytesview(path_bytes)
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

///|
fn encode_children_request(
  xid : Int32,
  path : String,
  op : Int32,
) -> Bytes raise ProtocolError {
  guard xid > 0 else { raise UnexpectedResponse(xid) }
  validate_path(path)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(op)
  write_jute_string(out, path)
  out.write_byte(b'\x00')
  finish_node_request(out)
}

///|
pub fn encode_get_children_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  encode_children_request(xid, path, 8)
}

///|
pub fn encode_get_children_with_stat_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  encode_children_request(xid, path, 12)
}

///|
fn read_children(payload : Bytes) -> (Array[String], Int32) raise ProtocolError {
  successful_reply(payload)
  guard payload.length() >= 20 else { raise TruncatedPayload }
  let rest = payload[16:].to_owned()
  guard rest is [i32be(count), ..] else { raise TruncatedPayload }
  guard count >= 0 else { raise InvalidBufferLength(count) }
  // Every name needs at least a four-byte length; reject impossible counts
  // before allocating the array or entering the loop.
  guard count <= (rest.length() - 4) / 4 else { raise TruncatedPayload }
  let children : Array[String] = []
  let mut offset = 4
  for _ in 0..<count {
    guard offset <= rest.length() - 4 else { raise TruncatedPayload }
    let tail = rest[offset:].to_owned()
    guard tail is [i32be(length), ..] else { raise TruncatedPayload }
    guard length >= 0 else { raise InvalidBufferLength(length) }
    offset += 4
    guard length <= rest.length() - offset else { raise TruncatedPayload }
    let name = @utf8.decode(rest[offset:offset + length].exact_view()) catch {
      _ => raise InvalidPath("invalid UTF-8 child name")
    }
    children.push(name)
    offset += length
  }
  (children, 16 + offset)
}

///|
pub fn decode_get_children_response(
  payload : Bytes,
) -> Array[String] raise ProtocolError {
  let (children, offset) = read_children(payload)
  guard offset == payload.length() else {
    raise TrailingBytes(payload.length() - offset)
  }
  children
}

///|
pub fn decode_get_children_with_stat_response(
  payload : Bytes,
) -> ChildrenResult raise ProtocolError {
  let (children, offset) = read_children(payload)
  let stat = decode_stat_body(payload[offset:].to_owned())
  { children, stat, }
}
