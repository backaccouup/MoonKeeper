// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub const PERM_READ : Int32 = 1

///|
pub const PERM_WRITE : Int32 = 2

///|
pub const PERM_CREATE : Int32 = 4

///|
pub const PERM_DELETE : Int32 = 8

///|
pub const PERM_ADMIN : Int32 = 16

///|
pub const PERM_ALL : Int32 = 31

///|
#derive(Debug, Eq)
pub(all) struct AclResult {
  acl : Array[Acl]
  stat : Stat
}

///|
pub extend AclResult with @debug.Debug::{to_repr}

///|
pub extend AclResult with Eq::{equal, not_equal}

///|
/// ZooKeeper expands auth:"" into this session's authenticated identities.
pub fn creator_acl() -> Array[Acl] {
  [{ permissions: PERM_ALL, scheme: "auth", id: "", }]
}

///|
fn write_acl_vector(
  out : @buffer.Buffer,
  entries : Array[Acl],
) -> Unit raise ProtocolError {
  guard !entries.is_empty() else { raise InvalidAcl("ACL must not be empty") }
  out.write_int_be(entries.length())
  for entry in entries {
    guard entry.permissions > 0 &&
      entry.permissions <= PERM_ALL &&
      !entry.scheme.is_empty() &&
      (entry.scheme == "auth" || !entry.id.is_empty()) else {
      raise InvalidAcl("invalid permissions or identity")
    }
    out.write_int_be(entry.permissions)
    write_jute_string(out, entry.scheme)
    write_jute_string(out, entry.id)
  }
}

///|
/// The returned frame contains the cleartext credential and must stay private.
pub fn encode_auth_request(
  scheme : String,
  credential : Bytes,
) -> Bytes raise ProtocolError {
  guard scheme == "digest" && credential.find(b":") is Some(n) && n > 0 else {
    raise InvalidAuth
  }
  // 26 bytes precede the credential in the digest AuthPacket's framed payload.
  let payload_size = Int32::min(credential.length(), 2147483647 - 26) + 26
  guard payload_size <= 1048576 else { raise FrameTooLarge(payload_size) }
  ignore(@utf8.decode(credential) catch { _ => raise InvalidAuth })
  let out = @buffer.Buffer()
  out.write_int_be(-4)
  out.write_int_be(100)
  out.write_int_be(0)
  write_jute_string(out, scheme)
  write_jute_buffer(out, Some(credential))
  finish_node_request(out)
}

///|
pub fn decode_auth_response(payload : Bytes) -> Unit raise ProtocolError {
  let header = decode_reply_header(payload)
  guard header.xid == -4 else { raise UnexpectedResponse(header.xid) }
  guard payload.length() == 16 else {
    raise TrailingBytes(payload.length() - 16)
  }
  guard header.err == 0 else { raise ServerError(header.err) }
}

///|
pub fn encode_get_acl_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, true)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(6)
  write_jute_string(out, path)
  finish_node_request(out)
}

///|
pub fn encode_set_acl_request(
  xid : Int32,
  path : String,
  acl : Array[Acl],
  version : Int32,
) -> Bytes raise ProtocolError {
  validate_node_request(xid, path, true)
  validate_version(version)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(7)
  write_jute_string(out, path)
  write_acl_vector(out, acl)
  out.write_int_be(version)
  finish_node_request(out)
}

///|
fn read_acl_string(
  input : BytesView,
) -> (String, BytesView) raise ProtocolError {
  guard input is [i32be(length), .. bytes] else { raise TruncatedPayload }
  guard length >= 0 else { raise InvalidBufferLength(length) }
  guard length <= bytes.length() else { raise TruncatedPayload }
  let value = @utf8.decode(bytes[:length], ignore_bom=false) catch {
    _ => raise InvalidAcl("invalid UTF-8 in ACL")
  }
  (value, bytes[length:])
}

///|
pub fn decode_get_acl_response(
  payload : Bytes,
) -> AclResult raise ProtocolError {
  successful_reply(payload)
  // Reserve the fixed-size Stat first so it cannot be consumed as vector data.
  guard payload.length() >= 16 + 4 + 68 else { raise TruncatedPayload }
  let stat_start = payload.length() - 68
  guard payload[16:stat_start] is [i32be(count), .. entries] else {
    raise TruncatedPayload
  }
  guard count >= 0 else { raise InvalidBufferLength(count) }
  guard count <= entries.length() / 12 else { raise TruncatedPayload }
  let acl : Array[Acl] = []
  let mut remaining = entries
  for _ in 0..<count {
    guard remaining is [i32be(permissions), .. strings] else {
      raise TruncatedPayload
    }
    let (scheme, tail) = read_acl_string(strings)
    let (id, next) = read_acl_string(tail)
    acl.push({ permissions, scheme, id, })
    remaining = next
  }
  guard remaining.length() == 0 else { raise TrailingBytes(remaining.length()) }
  { acl, stat: decode_stat_body(payload[stat_start:].to_owned()), }
}

///|
pub fn decode_set_acl_response(payload : Bytes) -> Stat raise ProtocolError {
  decode_set_data_response(payload)
}
