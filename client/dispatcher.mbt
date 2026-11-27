// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn Client::stop_io(self : Client, reason : ClientError) -> Unit {
  self.generation += 1
  if self.reader_task is Some(t) {
    t.cancel()
  }
  if self.heartbeat_task is Some(t) {
    t.cancel()
  }
  for _, slot in self.pending {
    (slot.reject)(reason)
    if slot.watch is Some(w) {
      w.cancel()
    }
  }
  self.pending.clear()
}

///|
fn Client::emit_state(self : Client, state : ClientState) -> Unit {
  self.current_state = state
  if self.state_stream_closed {
    return
  }
  if !(self.state_events.try_put(state) catch { _ => false }) {
    self.state_stream_closed = true
    self.state_events.close(error=WatchOverflow, clear=true)
  }
}

///|
fn Client::end_session(
  self : Client,
  state : ClientState,
  reason : ClientError,
) -> Unit {
  if self.current_state is Closed ||
    self.current_state is Expired ||
    self.current_state is AuthFailed {
    return
  }
  self.emit_state(state)
  self.stop_io(reason)
  self.close_watches()
  self.auth_frames.clear()
  self.password = b""
  if !self.state_stream_closed {
    self.state_stream_closed = true
    self.state_events.close()
  }
}

///|
fn Client::mark_disconnected(self : Client, reason : ClientError) -> Unit {
  guard self.current_state == Connected else { return }
  guard self.options.reconnect is Some(policy) else {
    self.end_session(Disconnected, reason)
    return
  }
  self.emit_state(Disconnected)
  self.stop_io(reason)
  self.recovery = Some(
    self.group.spawn(() => self.restore(policy), no_wait=true),
  )
}

///|
/// Send closeSession on the live transport before releasing it. Cleanup also
/// runs if cancellation or a network failure interrupts the best-effort write.
pub async fn Client::close(self : Client) -> Unit {
  if self.current_state == Closed {
    return
  }
  let live = self.current_state == Connected
  self.emit_state(Closed)
  defer {
    self.stop_io(ClientError::Closed)
    if self.recovery is Some(t) {
      t.cancel()
    }
    self.close_watches()
    self.auth_frames.clear()
    self.password = b""
    if !self.state_stream_closed {
      self.state_stream_closed = true
      self.state_events.close()
    }
  }
  if live {
    let xid = self.allocate_xid()
    ignore(
      @async.with_timeout_opt(self.request_timeout_ms, () => {
        self.lock.acquire()
        defer self.lock.release()
        @io.Writer::write(self.socket, @moonkeeper.encode_close_session(xid))
      }) catch {
        _ => None
      },
    )
  }
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
    0 => self.mark_disconnected(Disconnected)
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
    xid if xid > 0 || xid == -4 => {
      guard self.pending.get(xid) is Some(slot) else {
        raise UnexpectedXid(xid)
      }
      (slot.accept)(payload)
      self.pending.remove(xid)
      if slot.watch is Some(watch) {
        if reply.err == 0 || (watch.kind is Exists && reply.err == -101) {
          watch.missing = reply.err == -101
          watch.activate()
        } else {
          watch.cancel()
        }
      }
      if reply.err == 0 && slot.on_ack is Some(ack) {
        ack()
      }
      if reply.err == -115 {
        self.end_session(AuthFailed, Disconnected)
      }
      if reply.err == -112 {
        self.end_session(Expired, Disconnected)
      }
    }
    _ => raise UnexpectedXid(reply.xid)
  }
  // A multi can emit several notifications with one zxid. Only an ordinary
  // acknowledgement establishes that all preceding events were consumed.
  if reply.xid > 0 && reply.zxid > self.last_zxid {
    self.last_zxid = reply.zxid
  }
}

///|
async fn read_reply(socket : @socket.Tcp, limit : Int32) -> Bytes {
  guard @io.Reader::read_exactly(socket, 4) is [i32be(length)] &&
    length >= 16 &&
    length <= limit else {
    raise InvalidResponse
  }
  @io.Reader::read_exactly(socket, length)
}

///|
async fn Client::read_loop(
  self : Client,
  socket : @socket.Tcp,
  generation : Int32,
) -> Unit {
  defer socket.close()
  // close() marks the client Closed before writing closeSession. The reader
  // retains ownership of the socket until stop_io invalidates its generation.
  while self.generation == generation {
    try {
      let payload = read_reply(socket, self.max_frame_size)
      guard self.generation == generation else { return }
      if self.current_state == Closed {
        continue
      }
      self.last_receive_ms = @async.now()
      self.dispatch_payload(payload)
    } catch {
      error => {
        if self.generation == generation && !@async.is_cancellation_error(error) {
          let reason = match error {
            ClientError::_ as e => e
            @moonkeeper.ProtocolError::_ as e => Protocol(e)
            _ => Transport(error.to_string())
          }
          self.mark_disconnected(reason)
        }
        return
      }
    }
  }
}

///|
fn Client::start_io(self : Client) -> Unit {
  let socket = self.socket
  let generation = self.generation
  self.reader_task = Some(
    self.group.spawn(() => self.read_loop(socket, generation), no_wait=true),
  )
  self.heartbeat_task = Some(
    self.group.spawn(() => self.heartbeat_loop(generation), no_wait=true),
  )
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
async fn Client::heartbeat_loop(self : Client, generation : Int32) -> Unit {
  let interval = Int32::max(1, self.info.session_timeout_ms / 3)
  for ;; {
    @async.sleep(interval)
    if self.generation != generation || self.current_state != Connected {
      return
    }
    if @async.now() - self.last_receive_ms >=
      self.info.session_timeout_ms.to_int64() * 2L / 3L {
      self.mark_disconnected(Transport("session lost contact with server"))
      return
    }
    let budget = Int64::max(
      1L,
      self.last_receive_ms +
      self.info.session_timeout_ms.to_int64() * 2L / 3L -
      @async.now(),
    ).to_int()
    @async.with_timeout(budget, () => self.send_ping()) catch {
      error => {
        if self.generation == generation && !@async.is_cancellation_error(error) {
          self.mark_disconnected(Transport(error.to_string()))
        }
        return
      }
    }
  }
}
