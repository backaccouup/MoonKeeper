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

///|
#derive(Debug, Eq)
pub(all) struct Acl {
  permissions : Int32
  scheme : String
  id : String
}

///|
pub extend Acl with @debug.Debug::{to_repr}

///|
pub extend Acl with Eq::{equal, not_equal}

///|
/// ZooKeeper's world:anyone ACL with all five permissions.
pub fn open_acl_unsafe() -> Array[Acl] {
  [{ permissions: 31, scheme: "world", id: "anyone", }]
}

///|
#derive(Debug, Eq)
pub(all) enum CreateMode {
  Persistent
  Ephemeral
  PersistentSequential
  EphemeralSequential
}

///|
pub extend CreateMode with @debug.Debug::{to_repr}

///|
pub extend CreateMode with Eq::{equal, not_equal}

///|
pub(all) struct CreateOptions {
  mode : CreateMode
  acl : Array[Acl]
}

///|
pub fn CreateOptions::new(mode : CreateMode, acl : Array[Acl]) -> CreateOptions {
  { mode, acl, }
}

///|
#derive(Debug, Eq)
pub(all) struct DataResult {
  data : Bytes?
  stat : Stat
}

///|
pub extend DataResult with @debug.Debug::{to_repr}

///|
pub extend DataResult with Eq::{equal, not_equal}

///|
#derive(Debug, Eq)
pub(all) struct ChildrenResult {
  children : Array[String]
  stat : Stat
}

///|
pub extend ChildrenResult with @debug.Debug::{to_repr}

///|
pub extend ChildrenResult with Eq::{equal, not_equal}
