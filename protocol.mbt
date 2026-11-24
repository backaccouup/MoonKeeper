// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub fn decode_reply_header(payload : Bytes) -> ReplyHeader raise ProtocolError {
  guard payload is [i32be(xid), i64be(zxid), i32be(err), ..] else {
    raise TruncatedPayload
  }
  { xid, zxid, err, }
}
