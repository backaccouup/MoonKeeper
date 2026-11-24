// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// Check a znode and return its complete Stat. NoNode is the only error
/// converted to None; other server errors remain explicit.
pub async fn Client::exists(self : Client, path : String) -> @moonkeeper.Stat? {
  @moonkeeper.validate_path(path) catch {
    error => raise Protocol(error)
  }
  let mut acquired = false
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
      // Never reuse an xid on this connection. Exhaustion is explicit.
      guard xid > 0 else { raise QueueFull }
      self.next_xid = if xid == 2147483647 { 0 } else { xid + 1 }
      let request = @moonkeeper.encode_exists_request(xid, path)
      @io.Writer::write(self.socket, request)
      let header = @io.Reader::read_exactly(self.socket, 4)
      let length = match header {
        [i32be(n)] if n >= 16 && n <= 1048576 => n
        _ => raise InvalidResponse
      }
      let payload = @io.Reader::read_exactly(self.socket, length)
      let reply = @moonkeeper.decode_reply_header(payload)
      guard reply.xid == xid else { raise UnexpectedXid(reply.xid) }
      @moonkeeper.decode_exists_response(payload)
    },
  ) catch {
    ClientError::Closed => raise ClientError::Closed
    ClientError::Disconnected => raise ClientError::Disconnected
    @moonkeeper.ProtocolError::ServerError(code) => raise Server(code)
    @moonkeeper.ProtocolError::_ as error => {
      if self.current_state != ClientState::Closed {
        self.current_state = Disconnected
      }
      self.socket.close()
      raise Protocol(error)
    }
    error => {
      if self.current_state != ClientState::Closed {
        self.current_state = Disconnected
      }
      self.socket.close()
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
