// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) enum MultiOp {
  Create(String, Bytes?, CreateOptions)
  SetData(String, Bytes?, Int32)
  Delete(String, Int32)
  Check(String, Int32)
}

///|
#derive(Debug, Eq)
pub(all) enum MultiOpResult {
  Created(String)
  DataSet(Stat)
  Deleted
  Checked
  Failed(Int32)
  /// The raw server status is 0 before the failing operation and -2 after it.
  NotApplied(Int32)
}

///|
pub extend MultiOpResult with @debug.Debug::{to_repr}

///|
pub extend MultiOpResult with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) enum MultiOutcome {
  Committed(Array[MultiOpResult])
  /// Zero-based index of the first failure, followed by all per-operation statuses.
  Aborted(Int32, Array[MultiOpResult])
}

///|
pub extend MultiOutcome with @debug.Debug::{to_repr}

///|
pub extend MultiOutcome with Eq::{equal, not_equal}

///|
fn MultiOp::opcode(self : MultiOp) -> Int32 {
  match self {
    Create(_, _, _) => 1
    Delete(_, _) => 2
    SetData(_, _, _) => 5
    Check(_, _) => 13
  }
}

///|
pub fn encode_multi_request(
  xid : Int32,
  ops : Array[MultiOp],
  max_frame_size~ : Int32 = 1048576,
) -> Bytes raise ProtocolError {
  guard xid > 0 else { raise UnexpectedResponse(xid) }
  guard !ops.is_empty() else { raise InvalidMulti("empty transaction") }
  let out = @buffer.Buffer()
  out.write_int_be(xid)
  out.write_int_be(14)
  for op in ops {
    out.write_int_be(op.opcode())
    out.write_byte(b'\x00')
    out.write_int_be(-1)
    match op {
      Create(path, data, options) => write_create_body(out, path, data, options)
      SetData(path, data, version) =>
        write_set_data_body(out, path, data, version)
      Delete(path, version) =>
        write_path_version(out, path, version, allow_root=false)
      Check(path, version) =>
        write_path_version(out, path, version, allow_root=true)
    }
    let size = out.length() + 9
    guard size <= max_frame_size && size <= 1048576 else {
      raise FrameTooLarge(size)
    }
  }
  out.write_bytesview(b"\xff\xff\xff\xff\x01\xff\xff\xff\xff")
  finish_node_request(out)
}

///|
pub fn decode_multi_response(
  payload : Bytes,
  ops : Array[MultiOp],
) -> MultiOutcome raise ProtocolError {
  let reply = decode_reply_header(payload)
  if reply.err != 0 {
    guard payload.length() == 16 else {
      raise TrailingBytes(payload.length() - 16)
    }
    raise ServerError(reply.err)
  }
  guard !ops.is_empty() else { raise InvalidMulti("empty transaction") }
  let results : Array[MultiOpResult] = []
  let mut offset = 16
  let mut error_response = false
  let mut failed_index = -1
  for index, expected in ops {
    guard payload[offset:] is [i32be(op), b'\x00', i32be(err), ..] else {
      raise InvalidMulti("missing operation header")
    }
    offset += 9
    if index == 0 {
      error_response = op == -1
    }
    guard (op == -1) == error_response else {
      raise InvalidMulti("mixed success and error records")
    }
    if error_response {
      guard payload[offset:] is [i32be(code), ..] else {
        raise TruncatedPayload
      }
      offset += 4
      guard code == err else { raise InvalidMulti("conflicting error codes") }
      if code == 0 || (failed_index >= 0 && code == -2) {
        results.push(NotApplied(code))
      } else {
        if failed_index < 0 {
          failed_index = index
        }
        results.push(Failed(code))
      }
      continue
    }
    guard op == expected.opcode() && err == 0 else {
      raise InvalidMulti("operation result does not match request")
    }
    match expected {
      Create(_, _, _) => {
        guard payload[offset:] is [i32be(length), ..] else {
          raise TruncatedPayload
        }
        guard length >= 0 else { raise InvalidBufferLength(length) }
        offset += 4
        guard length <= payload.length() - offset else {
          raise TruncatedPayload
        }
        let path = @utf8.decode(payload[offset:offset + length].exact_view()) catch {
          _ => raise InvalidPath("invalid UTF-8 response path")
        }
        validate_path(path)
        results.push(Created(path))
        offset += length
      }
      SetData(_, _, _) => {
        guard payload.length() - offset >= 68 else { raise TruncatedPayload }
        results.push(
          DataSet(decode_stat_body(payload[offset:offset + 68].to_owned())),
        )
        offset += 68
      }
      Delete(_, _) => results.push(Deleted)
      Check(_, _) => results.push(Checked)
    }
  }
  guard payload[offset:] is [i32be(-1), b'\x01', i32be(-1)] else {
    raise InvalidMulti("expected final multi header")
  }
  if error_response {
    guard failed_index >= 0 else {
      raise InvalidMulti("missing failure status")
    }
    Aborted(failed_index, results)
  } else {
    Committed(results)
  }
}
