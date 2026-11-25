// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn Client::end_session(
  self : Client,
  state : ClientState,
  reason : ClientError,
) -> Unit {
  if self.current_state == Closed ||
    self.current_state == Disconnected ||
    self.current_state == Expired ||
    self.current_state == AuthFailed {
    return
  }
  self.current_state = state
  if self.reader_task is Some(task) {
    task.cancel()
  }
  if self.heartbeat_task is Some(task) {
    task.cancel()
  }
  if self.reader_task is None {
    self.socket.close()
  }
  if self.response_slot is Some(slot) {
    slot.close(error=reason)
  }
  self.response_slot = None
  self.pending_registration = None
  self.close_watches()
  if !(self.state_events.try_put(state) catch { _ => false }) {
    self.state_events.close(error=WatchOverflow, clear=true)
  } else {
    self.state_events.close()
  }
}

///|
fn Client::mark_disconnected(self : Client, reason : ClientError) -> Unit {
  self.end_session(Disconnected, reason)
}

///|
fn Client::dispatch_node_event(
  self : Client,
  event : @moonkeeper.WatchEvent,
) -> Unit {
  for watch in self.watches {
    if watch.accepts(event) {
      watch.deliver(event)
    }
  }
  self.prune_watches()
}

///|
fn Client::dispatch_state_event(self : Client, state : Int32) -> Unit {
  match state {
    0 => self.end_session(Disconnected, Disconnected)
    -112 => self.end_session(Expired, Disconnected)
    4 => self.end_session(AuthFailed, Disconnected)
    3 => () // Initial SyncConnected is already represented by with_client.
    _ => ()
  }
}

///|
fn Client::dispatch_payload(self : Client, payload : Bytes) -> Unit raise {
  let reply = @moonkeeper.decode_reply_header(payload)
  match reply.xid {
    -1 =>
      match @moonkeeper.decode_watch_notification(payload) {
        @moonkeeper.WatchNotice::Node(event) => self.dispatch_node_event(event)
        @moonkeeper.WatchNotice::State(state) =>
          self.dispatch_state_event(state)
      }
    -2 => {
      guard reply.err == 0 && payload.length() == 16 else {
        raise InvalidResponse
      }
    }
    xid if xid > 0 => {
      guard xid == self.response_xid && self.response_slot is Some(slot) else {
        raise UnexpectedXid(xid)
      }
      if self.pending_registration is Some(watch) {
        self.pending_registration = None
        if reply.err == 0 || (watch.kind is Exists && reply.err == -101) {
          // Registration becomes visible before the next network frame.
          watch.activate()
        } else {
          watch.cancel()
        }
      }
      self.response_slot = None
      guard slot.try_put(payload) else { raise InvalidResponse }
    }
    _ => raise UnexpectedXid(reply.xid)
  }
}

///|
async fn Client::read_loop(self : Client) -> Unit {
  defer self.socket.close()
  for ;; {
    if self.current_state != Connected {
      return
    }
    let header = @io.Reader::read_exactly(self.socket, 4) catch {
      error => {
        if !@async.is_cancellation_error(error) {
          self.mark_disconnected(Transport(error.to_string()))
        }
        return
      }
    }
    let length = match header {
      [i32be(n)] if n >= 16 && n <= self.max_frame_size => n
      _ => {
        self.mark_disconnected(InvalidResponse)
        return
      }
    }
    let payload = @io.Reader::read_exactly(self.socket, length) catch {
      error => {
        if !@async.is_cancellation_error(error) {
          self.mark_disconnected(Transport(error.to_string()))
        }
        return
      }
    }
    self.last_receive_ms = @async.now()
    self.dispatch_payload(payload) catch {
      ClientError::_ as error => {
        self.mark_disconnected(error)
        return
      }
      @moonkeeper.ProtocolError::_ as error => {
        self.mark_disconnected(Protocol(error))
        return
      }
      error => {
        self.mark_disconnected(Transport(error.to_string()))
        return
      }
    }
  }
}

///|
async fn Client::send_ping(self : Client) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if self.current_state == Connected {
    @io.Writer::write(
      self.socket,
      b"\x00\x00\x00\x08\xff\xff\xff\xfe\x00\x00\x00\x0b",
    )
  }
}

///|
async fn Client::heartbeat_loop(self : Client) -> Unit {
  let interval = Int32::max(500, self.info.session_timeout_ms / 3)
  for ;; {
    @async.sleep(interval)
    if self.current_state != Connected {
      return
    }
    if @async.now() - self.last_receive_ms >=
      self.info.session_timeout_ms.to_int64() {
      self.mark_disconnected(Transport("session lost contact with server"))
      return
    }
    self.send_ping() catch {
      error => {
        if !@async.is_cancellation_error(error) {
          self.mark_disconnected(Transport(error.to_string()))
        }
        return
      }
    }
  }
}
