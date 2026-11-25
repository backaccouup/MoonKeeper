// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// Execute one request at a time on this connection. The lock also protects xid
/// allocation. A failed exchange closes TCP, so a late reply cannot be reused.
async fn[T] Client::request(
  self : Client,
  encode : (Int32) -> Bytes raise @moonkeeper.ProtocolError,
  decode : (Bytes) -> T raise @moonkeeper.ProtocolError,
  is_write : Bool,
  watch~ : Watch? = None,
) -> T {
  let mut acquired = false
  let mut possibly_sent = false
  defer (if acquired { self.lock.release() })
  let deadline = @async.now() + self.request_timeout_ms.to_int64()
  let result = @async.with_timeout(
    self.request_timeout_ms,
    error=RequestTimeout,
    () => {
      self.lock.acquire()
      acquired = true
      guard self.current_state == Connected else {
        if self.current_state == ClientState::Closed {
          raise ClientError::Closed
        } else {
          raise ClientError::Disconnected
        }
      }
      let xid = self.next_xid
      guard xid > 0 else { raise QueueFull }
      let wire = encode(xid)
      @moonkeeper.validate_request_frame_size(wire, self.max_frame_size)
      self.next_xid = if xid == 2147483647 { 0 } else { xid + 1 }
      let response : @aqueue.Queue[Bytes] = @aqueue.Queue::Queue(
        kind=@aqueue.Kind::Blocking(1),
      )
      self.response_slot = Some(response)
      self.response_xid = xid
      self.pending_registration = watch
      if watch is Some(subscription) {
        self.watches.push(subscription)
      }
      // A partial write can reach ZooKeeper even if Writer::write fails.
      possibly_sent = true
      @io.Writer::write(self.socket, wire)
      let payload = response.get()
      decode(payload)
    },
  ) catch {
    ClientError::Closed =>
      if is_write && possibly_sent {
        raise OutcomeUnknown
      } else {
        raise ClientError::Closed
      }
    ClientError::Disconnected =>
      if is_write && possibly_sent {
        raise OutcomeUnknown
      } else {
        raise ClientError::Disconnected
      }
    ClientError::QueueFull => raise ClientError::QueueFull
    ClientError::UnexpectedXid(_) as error =>
      if is_write && possibly_sent {
        raise OutcomeUnknown
      } else {
        raise error
      }
    ClientError::InvalidResponse =>
      if is_write && possibly_sent {
        raise OutcomeUnknown
      } else {
        raise ClientError::InvalidResponse
      }
    @moonkeeper.ProtocolError::ServerError(code) => raise Server(code)
    @moonkeeper.ProtocolError::_ as error => {
      if !possibly_sent {
        raise Protocol(error)
      }
      self.mark_disconnected(Protocol(error))
      if is_write {
        raise OutcomeUnknown
      }
      raise Protocol(error)
    }
    error => {
      self.mark_disconnected(Transport(error.to_string()))
      if is_write && possibly_sent {
        raise OutcomeUnknown
      }
      if error is ClientError::RequestTimeout ||
        (@async.is_cancellation_error(error) && @async.now() >= deadline) {
        raise ClientError::RequestTimeout
      }
      if @async.is_cancellation_error(error) {
        raise error
      }
      raise Transport(error.to_string())
    }
  }
  result
}

///|
/// NoNode is the only server error represented as None.
pub async fn Client::exists(self : Client, path : String) -> @moonkeeper.Stat? {
  self.request(
    xid => @moonkeeper.encode_exists_request(xid, path),
    payload => @moonkeeper.decode_exists_response(payload),
    false,
  )
}

///|
pub async fn Client::create(
  self : Client,
  path : String,
  data : Bytes?,
  options : @moonkeeper.CreateOptions,
) -> String {
  self.request(
    xid => @moonkeeper.encode_create_request(xid, path, data, options),
    payload => @moonkeeper.decode_create_response(payload),
    true,
  )
}

///|
pub async fn Client::get_data(
  self : Client,
  path : String,
) -> @moonkeeper.DataResult {
  self.request(
    xid => @moonkeeper.encode_get_data_request(xid, path),
    payload => @moonkeeper.decode_get_data_response(payload),
    false,
  )
}

///|
pub async fn Client::set_data(
  self : Client,
  path : String,
  data : Bytes?,
  version : Int32,
) -> @moonkeeper.Stat {
  self.request(
    xid => @moonkeeper.encode_set_data_request(xid, path, data, version),
    payload => @moonkeeper.decode_set_data_response(payload),
    true,
  )
}

///|
pub async fn Client::delete(
  self : Client,
  path : String,
  version : Int32,
) -> Unit {
  self.request(
    xid => @moonkeeper.encode_delete_request(xid, path, version),
    payload => @moonkeeper.decode_delete_response(payload),
    true,
  )
}

///|
/// Returns child names in server order; callers should sort if needed.
pub async fn Client::get_children(
  self : Client,
  path : String,
) -> Array[String] {
  self.request(
    xid => @moonkeeper.encode_get_children_request(xid, path),
    payload => @moonkeeper.decode_get_children_response(payload),
    false,
  )
}

///|
/// Returns the same child names together with the parent node's full Stat.
pub async fn Client::get_children_with_stat(
  self : Client,
  path : String,
) -> @moonkeeper.ChildrenResult {
  self.request(
    xid => @moonkeeper.encode_get_children_with_stat_request(xid, path),
    payload => @moonkeeper.decode_get_children_with_stat_response(payload),
    false,
  )
}
