// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// Confirm a digest identity with ZooKeeper. All authentication packets share
/// xid -4, so an overlapping add_auth call receives QueueFull.
pub async fn Client::add_auth(
  self : Client,
  scheme : String,
  credential : Bytes,
) -> Unit {
  guard self.auth_lock.try_acquire() else { raise ClientError::QueueFull }
  defer self.auth_lock.release()
  let frame = @moonkeeper.encode_auth_request(scheme, credential) catch {
    error => raise Protocol(error)
  }
  self.request(
    _ => frame,
    @moonkeeper.decode_auth_response,
    false,
    reserved_xid=Some(-4),
    on_ack=Some(() => {
      if !self.auth_frames.contains(frame) {
        self.auth_frames.push(frame)
      }
    }),
  )
}

///|
pub async fn Client::get_acl(
  self : Client,
  path : String,
) -> @moonkeeper.AclResult {
  self.request(
    xid => @moonkeeper.encode_get_acl_request(xid, path),
    @moonkeeper.decode_get_acl_response,
    false,
  )
}

///|
/// Use Stat.aversion for a conditional update, or -1 to accept any version.
pub async fn Client::set_acl(
  self : Client,
  path : String,
  acl : Array[@moonkeeper.Acl],
  version : Int32,
) -> @moonkeeper.Stat {
  self.request(
    xid => @moonkeeper.encode_set_acl_request(xid, path, acl, version),
    @moonkeeper.decode_set_acl_response,
    true,
  )
}
