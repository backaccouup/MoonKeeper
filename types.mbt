// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) struct RequestHeader {
  xid : Int32
  op : Int32
}

///|
pub(all) struct ReplyHeader {
  xid : Int32
  zxid : Int64
  err : Int32
}

///|
#derive(Debug, Eq)
pub(all) struct Stat {
  czxid : Int64
  mzxid : Int64
  ctime : Int64
  mtime : Int64
  version : Int32
  cversion : Int32
  aversion : Int32
  ephemeral_owner : Int64
  data_length : Int32
  num_children : Int32
  pzxid : Int64
}

///|
pub extend Stat with @debug.Debug::{to_repr}

///|
pub extend Stat with Eq::{equal, not_equal}
