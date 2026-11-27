// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
priv struct Pending {
  accept : (Bytes) -> Unit raise @moonkeeper.ProtocolError
  reject : (ClientError) -> Unit
  watch : Watch?
  on_ack : (() -> Unit)?
}

///|
fn Client::allocate_xid(self : Client) -> Int32 {
  while self.pending.contains(self.next_xid) {
    self.next_xid = if self.next_xid == 2147483647 {
      1
    } else {
      self.next_xid + 1
    }
  }
  let xid = self.next_xid
  self.next_xid = if xid == 2147483647 { 1 } else { xid + 1 }
  xid
}

///|
/// The mutex protects only complete wire writes. Reply slots remain independent.
async fn[T] Client::request(
  self : Client,
  encode : (Int32) -> Bytes raise @moonkeeper.ProtocolError,
  decode : (Bytes) -> T raise @moonkeeper.ProtocolError,
  is_write : Bool,
  watch~ : Watch? = None,
  reserved_xid~ : Int32? = None,
  on_ack~ : (() -> Unit)? = None,
) -> T {
  guard self.current_state == Connected else {
    if self.current_state == Closed {
      raise ClientError::Closed
    }
    raise ClientError::Disconnected
  }
  guard self.pending.length() < self.options.max_pending_requests else {
    raise QueueFull
  }
  if self.options.reconnect is Some(_) && watch is Some(w) {
    let restore_size = 32 + @utf8.encode(w.path).length()
    if restore_size > self.max_frame_size {
      raise InvalidOptions(
        "watch path exceeds configured session recovery frame limit",
      )
    }
  }
  let generation = self.generation
  let previous_xid = self.next_xid
  let xid = match reserved_xid {
    Some(id) => id
    None => self.allocate_xid()
  }
  guard !self.pending.contains(xid) else { raise QueueFull }
  let wire = try {
    let bytes = encode(xid)
    @moonkeeper.validate_request_frame_size(bytes, self.max_frame_size)
    bytes
  } catch {
    error => {
      self.next_xid = previous_xid
      raise Protocol(error)
    }
  }
  let response : @aqueue.Queue[T] = @aqueue.Queue::Queue(kind=Blocking(1))
  let mut answered = false
  self.pending[xid] = {
    accept: payload => {
      answered = true
      let value = decode(payload) catch {
        @moonkeeper.ProtocolError::ServerError(code) => {
          response.close(error=Server(code))
          return
        }
        err => raise err
      }
      ignore(response.try_put(value) catch { _ => false })
    },
    reject: reason => response.close(error=reason),
    watch,
    on_ack,
  }
  if watch is Some(w) {
    self.watches.push(w)
  }
  let mut started = false
  let mut written = false
  // Cancellation in RC1 unwinds defer without entering catch. Retire unsent
  // requests and discard a connection that may contain a partial frame.
  defer (if !answered && self.generation == generation {
    if !started {
      self.pending.remove(xid)
    }
    if started && (!written || xid < 0) && self.current_state == Connected {
      self.mark_disconnected(Disconnected)
    }
  })
  @async.with_timeout(self.request_timeout_ms, error=RequestTimeout, () => {
    self.lock.acquire()
    {
      defer self.lock.release()
      guard self.generation == generation && self.current_state == Connected else {
        raise ClientError::Disconnected
      }
      started = true
      @io.Writer::write(self.socket, wire)
      written = true
    }
    response.get()
  }) catch {
    error => {
      if error is ClientError::Server(_) {
        raise error
      }
      if is_write && started {
        raise OutcomeUnknown
      }
      if error is ClientError::_ {
        raise error
      }
      raise Transport(error.to_string())
    }
  }
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
