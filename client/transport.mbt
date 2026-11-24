// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn establish_session(
  socket : @socket.Tcp,
  options : ClientOptions,
) -> SessionInfo {
  let request = @moonkeeper.encode_connect_request(
    options.session_timeout_ms,
    read_only=options.read_only,
  )
  // Writer::write handles short writes until the full request has been sent.
  @io.Writer::write(socket, request)
  let decoder = @moonkeeper.FrameDecoder::new(
    max_frame_size=options.max_frame_size,
  )
  let mut header = b""
  let mut remaining = 4
  for ;; {
    // Read only the current frame. Later bytes stay in the socket/Reader buffer,
    // so success cannot depend on whether TCP coalesces following traffic.
    match @io.Reader::read_some(socket, max_len=Int32::min(remaining, 4096)) {
      None => {
        decoder.finish()
        raise ConnectionClosed
      }
      Some(chunk) => {
        if header.length() < 4 {
          header = header + chunk
        }
        let frames = decoder.feed(chunk)
        if frames.length() > 0 {
          let response = @moonkeeper.decode_connect_response(frames[0])
          guard response.session_timeout_ms > 0 else { raise SessionRejected }
          guard response.protocol_version == 0 else {
            raise UnsupportedProtocol(response.protocol_version)
          }
          guard response.session_id != 0L else {
            raise InvalidSession("zero session ID")
          }
          guard response.password is Some(password) && password.length() == 16 else {
            raise InvalidSession("expected a 16-byte session password")
          }
          guard !response.read_only || options.read_only else {
            raise ReadOnlyNotAllowed
          }
          return {
            session_id: response.session_id,
            session_timeout_ms: response.session_timeout_ms,
            read_only: response.read_only,
          }
        }
        remaining -= chunk.length()
        if remaining == 0 {
          // feed() has already validated this header before body allocation.
          remaining = match header {
            [i32be(length)] => length
            _ => abort("handshake header invariant")
          }
        }
        continue
      }
    }
  }
}
