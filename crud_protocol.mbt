// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn write_jute_string(out : @buffer.Buffer, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  out.write_int_be(bytes.length())
  out.write_bytes(bytes)
}

///|
fn write_jute_buffer(out : @buffer.Buffer, value : Bytes?) -> Unit {
  match value {
    None => out.write_int_be(-1)
    Some(bytes) => {
      out.write_int_be(bytes.length())
      out.write_bytes(bytes)
    }
  }
}

///|
fn finish_node_request(out : @buffer.Buffer) -> Bytes raise ProtocolError {
  let body = out.to_bytes()
  guard body.length() <= 1048576 else { raise FrameTooLarge(body.length()) }
  let frame = @buffer.Buffer()
  frame.write_int_be(body.length())
  frame.write_bytes(body)
  frame.to_bytes()
}

///|
pub fn validate_request_frame_size(
  wire : Bytes,
  max_frame_size : Int32,
) -> Unit raise ProtocolError {
  guard wire.length() >= 4 else { raise TruncatedFrame }
  guard wire.length() - 4 <= max_frame_size else {
    raise FrameTooLarge(wire.length() - 4)
  }
}

///|
fn validate_node_request(
  xid : Int32,
  path : String,
  allow_root : Bool,
) -> Unit raise ProtocolError {
  guard xid > 0 else { raise UnexpectedResponse(xid) }
  validate_path(path)
  guard allow_root || path != "/" else { raise InvalidPath(path) }
}

///|
fn validate_version(version : Int32) -> Unit raise ProtocolError {
  guard version >= -1 else { raise InvalidVersion(version) }
}

///|
pub fn encode_create_request(
  xid : Int32,
  path : String,
  data : Bytes?,
  options : CreateOptions,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, false)
  guard !options.acl.is_empty() else {
    raise InvalidAcl("ACL must not be empty")
  }
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(1)
  write_jute_string(out, path)
  write_jute_buffer(out, data)
  out.write_int_be(options.acl.length())
  for acl in options.acl {
    guard acl.permissions > 0 &&
      acl.permissions <= 31 &&
      !acl.scheme.is_empty() &&
      !acl.id.is_empty() else {
      raise InvalidAcl("permissions, scheme, and id must be valid")
    }
    out.write_int_be(acl.permissions)
    write_jute_string(out, acl.scheme)
    write_jute_string(out, acl.id)
  }
  match options.mode {
    Persistent => out.write_int_be(0)
  }
  finish_node_request(out)
}

///|
pub fn encode_get_data_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, true)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(4)
  write_jute_string(out, path)
  out.write_byte(b'\x00')
  finish_node_request(out)
}

///|
pub fn encode_set_data_request(
  xid : Int32,
  path : String,
  data : Bytes?,
  version : Int32,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, true)
  validate_version(version)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(5)
  write_jute_string(out, path)
  write_jute_buffer(out, data)
  out.write_int_be(version)
  finish_node_request(out)
}

///|
pub fn encode_delete_request(
  xid : Int32,
  path : String,
  version : Int32,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, false)
  validate_version(version)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(2)
  write_jute_string(out, path)
  out.write_int_be(version)
  finish_node_request(out)
}

///|
fn successful_reply(payload : Bytes) -> Unit raise ProtocolError {
  let reply = decode_reply_header(payload)
  guard payload.length() >= 16 else { raise TruncatedPayload }
  guard reply.err == 0 else { raise ServerError(reply.err) }
}

///|
fn decode_stat_body(body : Bytes) -> Stat raise ProtocolError {
  guard body
    is [
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
  {
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
  }
}

///|
pub fn decode_create_response(payload : Bytes) -> String raise ProtocolError {
  successful_reply(payload)
  let rest = payload[16:].to_owned()
  guard rest is [i32be(length), ..] else { raise TruncatedPayload }
  guard length >= 0 else { raise InvalidBufferLength(length) }
  guard length <= rest.length() - 4 else { raise TruncatedPayload }
  guard length == rest.length() - 4 else {
    raise TrailingBytes(rest.length() - 4 - length)
  }
  @utf8.decode(rest[4:].exact_view()) catch {
    _ => raise InvalidPath("invalid UTF-8 response path")
  }
}

///|
pub fn decode_get_data_response(
  payload : Bytes,
) -> DataResult raise ProtocolError {
  successful_reply(payload)
  let rest = payload[16:].to_owned()
  guard rest is [i32be(length), ..] else { raise TruncatedPayload }
  guard length >= -1 else { raise InvalidBufferLength(length) }
  let data_length = if length == -1 { 0 } else { length }
  guard data_length <= rest.length() - 4 else { raise TruncatedPayload }
  let data = if length == -1 {
    None
  } else {
    Some(rest[4:4 + length].to_owned())
  }
  let stat = decode_stat_body(rest[4 + data_length:].to_owned())
  { data, stat, }
}

///|
pub fn decode_set_data_response(payload : Bytes) -> Stat raise ProtocolError {
  successful_reply(payload)
  decode_stat_body(payload[16:].to_owned())
}

///|
pub fn decode_delete_response(payload : Bytes) -> Unit raise ProtocolError {
  successful_reply(payload)
  guard payload.length() == 16 else {
    raise TrailingBytes(payload.length() - 16)
  }
}
