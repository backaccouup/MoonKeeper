// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub fn encode_close_session(xid : Int32) -> Bytes {
  let out = @buffer.Buffer()
  out.write_int_be(8)
  out.write_int_be(xid)
  out.write_int_be(-11)
  out.to_bytes()
}

///|
pub fn encode_set_watches(
  zxid : Int64,
  data : Array[String],
  exists : Array[String],
  children : Array[String],
) -> Bytes raise ProtocolError {
  let out = @buffer.Buffer()
  out.write_int_be(-8)
  out.write_int_be(101)
  out.write_int64_be(zxid)
  for paths in [data, exists, children] {
    out.write_int_be(paths.length())
    for path in paths {
      validate_path(path)
      write_jute_string(out, path)
    }
  }
  finish_node_request(out)
}
