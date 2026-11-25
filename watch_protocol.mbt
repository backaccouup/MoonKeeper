// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#derive(Debug, Eq)
pub(all) enum WatchEventType {
  NodeCreated
  NodeDeleted
  NodeDataChanged
  NodeChildrenChanged
}

///|
pub extend WatchEventType with @debug.Debug::{to_repr}

///|
pub extend WatchEventType with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) struct WatchEvent {
  kind : WatchEventType
  path : String
}

///|
pub extend WatchEvent with @debug.Debug::{to_repr}

///|
pub extend WatchEvent with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) enum WatchNotice {
  Node(WatchEvent)
  State(Int32)
}

///|
pub extend WatchNotice with @debug.Debug::{to_repr}

///|
pub extend WatchNotice with Eq::{equal, not_equal}

///|
fn encode_watched_read(
  xid : Int32,
  op : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  guard xid > 0 else { raise UnexpectedResponse(xid) }
  validate_path(path)
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(op)
  write_jute_string(out, path)
  out.write_byte(b'\x01')
  finish_node_request(out)
}

///|
pub fn encode_watch_exists_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  encode_watched_read(xid, 3, path)
}

///|
pub fn encode_watch_data_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  encode_watched_read(xid, 4, path)
}

///|
pub fn encode_watch_children_request(
  xid : Int32,
  path : String,
) -> Bytes raise ProtocolError {
  encode_watched_read(xid, 12, path)
}

///|
/// Notification payload excludes the four-byte frame prefix.
pub fn decode_watch_notification(
  payload : Bytes,
) -> WatchNotice raise ProtocolError {
  let header = decode_reply_header(payload)
  guard header.xid == -1 && header.err == 0 else {
    raise UnexpectedResponse(header.xid)
  }
  guard payload
    is [
      i32be(_),
      i64be(_),
      i32be(_),
      i32be(event_type),
      i32be(state),
      i32be(path_length),
      .. path_bytes,
    ] else {
    raise TruncatedPayload
  }
  guard path_length >= -1 else { raise InvalidBufferLength(path_length) }
  let actual_length = if path_length == -1 { 0 } else { path_length }
  guard actual_length <= path_bytes.length() else { raise TruncatedPayload }
  guard actual_length == path_bytes.length() else {
    raise TrailingBytes(path_bytes.length() - actual_length)
  }
  if event_type == -1 {
    guard path_length == -1 || path_length == 0 else {
      raise InvalidPath("session notification must not have a path")
    }
    return WatchNotice::State(state)
  }
  guard path_length > 0 else {
    raise InvalidPath("node notification needs a path")
  }
  let path = @utf8.decode(path_bytes.exact_view()) catch {
    _ => raise InvalidPath("invalid notification UTF-8")
  }
  validate_path(path)
  let kind = match event_type {
    1 => WatchEventType::NodeCreated
    2 => WatchEventType::NodeDeleted
    3 => WatchEventType::NodeDataChanged
    4 => WatchEventType::NodeChildrenChanged
    _ => raise UnexpectedResponse(event_type)
  }
  WatchNotice::Node({ kind, path, })
}
