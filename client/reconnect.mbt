// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) struct ReconnectPolicy {
  attempts : Int32
  initial_delay_ms : Int32
  max_delay_ms : Int32
}

///|
pub fn ReconnectPolicy::new(
  attempts~ : Int32 = 12,
  initial_delay_ms~ : Int32 = 50,
  max_delay_ms~ : Int32 = 1000,
) -> ReconnectPolicy {
  { attempts, initial_delay_ms, max_delay_ms, }
}

///|
async fn dial(
  endpoint : Endpoint,
  options : ClientOptions,
  request : Bytes,
) -> (@socket.Tcp, SessionInfo, Bytes) {
  let socket = @socket.Tcp::connect_to_host(endpoint.host, port=endpoint.port)
  errdefer socket.close()
  let (info, password) = establish_session(socket, options, request)
  (socket, info, password)
}

///|
async fn open_initial(
  options : ClientOptions,
  endpoints : Array[Endpoint],
) -> (Int32, @socket.Tcp, SessionInfo, Bytes) {
  let request = @moonkeeper.encode_connect_request(
    options.session_timeout_ms,
    read_only=options.read_only,
  )
  let deadline = @async.now() + options.request_timeout_ms.to_int64()
  for index, endpoint in endpoints {
    let remaining = deadline - @async.now()
    guard remaining > 0L else { raise HandshakeTimeout }
    let budget = Int32::max(
      1,
      remaining.to_int() / (endpoints.length() - index),
    )
    try {
      let (socket, info, password) = @async.with_timeout(
        budget,
        error=HandshakeTimeout,
        () => dial(endpoint, options, request),
      )
      return (index, socket, info, password)
    } catch {
      error => {
        if @async.is_cancellation_error(error) {
          raise error
        }
        if index + 1 == endpoints.length() {
          match error {
            ClientError::_ as e => raise e
            @moonkeeper.ProtocolError::_ as e => raise Protocol(e)
            _ => raise Transport(error.to_string())
          }
        }
      }
    }
  }
  raise InvalidOptions("no endpoint")
}

///|
async fn Client::restore_exchange(
  self : Client,
  socket : @socket.Tcp,
  frame : Bytes,
  xid : Int32,
) -> Unit {
  @moonkeeper.validate_request_frame_size(frame, self.max_frame_size)
  @io.Writer::write(socket, frame)
  for ;; {
    let payload = read_reply(socket, self.max_frame_size)
    let header = @moonkeeper.decode_reply_header(payload)
    if header.xid == -1 {
      match @moonkeeper.decode_watch_notification(payload) {
        Node(event) => self.dispatch_node_event(event)
        State(-112) => raise SessionRejected
        State(4) => raise Server(-115)
        State(_) => ()
      }
      continue
    }
    guard header.xid == xid && payload.length() == 16 else {
      raise InvalidResponse
    }
    guard header.err == 0 else { raise Server(header.err) }
    return
  }
}

///|
async fn Client::restore_at(self : Client, index : Int32) -> Unit {
  let request = @moonkeeper.encode_resume_request(
    self.info.session_timeout_ms,
    self.info.session_id,
    self.password,
    self.last_zxid,
    read_only=self.options.read_only,
  )
  let (socket, info, password) = dial(
    self.endpoints[index],
    self.options,
    request,
  )
  errdefer socket.close()
  guard info.session_id == self.info.session_id else { raise SessionRejected }
  for frame in self.auth_frames {
    self.restore_exchange(socket, frame, -4)
  }
  let seen : Map[(Int32, String), Bool] = Map([])
  let data : Array[String] = []
  let exists : Array[String] = []
  let children : Array[String] = []
  let mut size = 28
  for watch in self.watches.copy() {
    if !watch.active || !watch.registered {
      continue
    }
    let kind = match watch.kind {
      Children => 2
      Exists if watch.missing => 1
      _ => 0
    }
    let key = (kind, watch.path)
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    let cost = 4 + @utf8.encode(watch.path).length()
    if size + cost > self.max_frame_size && size > 28 {
      self.restore_exchange(
        socket,
        @moonkeeper.encode_set_watches(self.last_zxid, data, exists, children),
        -8,
      )
      data.clear()
      exists.clear()
      children.clear()
      size = 28
    }
    match kind {
      0 => data.push(watch.path)
      1 => exists.push(watch.path)
      _ => children.push(watch.path)
    }
    size += cost
  }
  if size > 28 {
    self.restore_exchange(
      socket,
      @moonkeeper.encode_set_watches(self.last_zxid, data, exists, children),
      -8,
    )
  }
  guard self.current_state == Disconnected else { raise ClientError::Closed }
  self.socket = socket
  self.info = info
  self.password = password
  self.endpoint_index = index
  self.last_receive_ms = @async.now()
  self.emit_state(Connected)
  self.start_io()
}

///|
async fn Client::restore(self : Client, policy : ReconnectPolicy) -> Unit {
  let deadline = self.last_receive_ms + self.info.session_timeout_ms.to_int64()
  let mut delay = policy.initial_delay_ms
  for n in 1..<=policy.attempts {
    let left = deadline - @async.now()
    if left <= 0L || self.current_state != Disconnected {
      break
    }
    let jitter = ((@async.now() ^ self.info.session_id).abs() %
    (delay / 2 + 1).to_int64()).to_int()
    @async.sleep(Int64::min(left, (delay / 2 + jitter).to_int64()).to_int())
    let remaining = deadline - @async.now()
    if remaining <= 0L {
      break
    }
    let index = (self.endpoint_index + n) % self.endpoints.length()
    let budget = Int32::min(
      self.request_timeout_ms,
      Int32::max(1, remaining.to_int() / self.endpoints.length()),
    )
    try {
      @async.with_timeout(budget, () => self.restore_at(index))
      return
    } catch {
      ClientError::SessionRejected | ClientError::Server(-112) => {
        self.end_session(Expired, Disconnected)
        return
      }
      ClientError::Server(-115) => {
        self.end_session(AuthFailed, Server(-115))
        return
      }
      e => if @async.is_cancellation_error(e) { return }
    }
    delay = Int32::min(policy.max_delay_ms, delay * 2)
  }
  if self.current_state == Disconnected {
    // The reconnect budget is exhausted. Only mark the session expired after
    // its safe resume deadline, even when attempts ran out earlier.
    let remaining = deadline - @async.now()
    if remaining > 0L {
      @async.sleep(remaining.to_int())
    }
    if self.current_state == Disconnected {
      self.end_session(Expired, Disconnected)
    }
  }
}
