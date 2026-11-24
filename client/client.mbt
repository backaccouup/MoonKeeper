// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#derive(Debug, Eq)
pub(all) struct Endpoint {
  host : String
  port : Int32
}

///|
pub extend Endpoint with @debug.Debug::{to_repr}

///|
pub extend Endpoint with Eq::{equal, not_equal}

///|
pub fn Endpoint::new(host : String, port~ : Int32 = 2181) -> Endpoint {
  { host, port, }
}

///|
/// Request timeout bounds connection establishment and the handshake together.
/// Pending-request and event limits are reserved for the upcoming dispatcher.
pub(all) struct ClientOptions {
  endpoint : Endpoint
  session_timeout_ms : Int32
  request_timeout_ms : Int32
  max_frame_size : Int32
  max_pending_requests : Int32
  event_buffer_capacity : Int32
  read_only : Bool
}

///|
pub fn ClientOptions::new(
  endpoint : Endpoint,
  session_timeout_ms~ : Int32 = 30000,
  request_timeout_ms~ : Int32 = 10000,
  max_frame_size~ : Int32 = 1048576,
  max_pending_requests~ : Int32 = 256,
  event_buffer_capacity~ : Int32 = 256,
  read_only~ : Bool = false,
) -> ClientOptions {
  {
    endpoint,
    session_timeout_ms,
    request_timeout_ms,
    max_frame_size,
    max_pending_requests,
    event_buffer_capacity,
    read_only,
  }
}

///|
/// Negotiated, non-secret session metadata. Does not contain a password.
#derive(Debug, Eq)
pub struct SessionInfo {
  session_id : Int64
  session_timeout_ms : Int32
  read_only : Bool
}

///|
pub extend SessionInfo with @debug.Debug::{to_repr}

///|
pub extend SessionInfo with Eq::{equal, not_equal}

///|
pub struct Client {
  priv info : SessionInfo
  priv socket : @socket.Tcp
  priv lock : @async.Mutex
  priv mut next_xid : Int32
  priv request_timeout_ms : Int32
  priv max_frame_size : Int32
  priv mut current_state : ClientState
}

///|
pub fn Client::session_info(self : Client) -> SessionInfo {
  self.info
}

///|
#derive(Debug, Eq)
pub(all) enum ClientState {
  Connecting
  Connected
  Disconnected
  Expired
  AuthFailed
  Closed
}

///|
pub extend ClientState with @debug.Debug::{to_repr}

///|
pub extend ClientState with Eq::{equal, not_equal}

///|
pub fn Client::state(self : Client) -> ClientState {
  self.current_state
}

///|
pub fn Client::close(self : Client) -> Unit {
  if self.current_state != Closed {
    self.current_state = Closed
    self.socket.close()
  }
}

///|
fn validate_options(options : ClientOptions) -> Unit raise ClientError {
  guard !options.endpoint.host.is_empty() &&
    !options.endpoint.host.contains("\u0000") &&
    options.endpoint.port > 0 &&
    options.endpoint.port <= 65535 else {
    raise InvalidOptions(
      "host must be nonempty without NUL and port must be in 1..65535",
    )
  }
  guard options.session_timeout_ms > 0 && options.request_timeout_ms > 0 else {
    raise InvalidOptions("timeouts must be positive")
  }
  // The existing ConnectResponse decoder caps payloads at 1 MiB.
  guard options.max_frame_size >= 45 && options.max_frame_size <= 1048576 else {
    raise InvalidOptions("max_frame_size must be in 45..1048576")
  }
  guard options.max_pending_requests > 0 && options.event_buffer_capacity > 0 else {
    raise InvalidOptions("request and event limits must be positive")
  }
}

///|
/// Establish a new session, invoke `body`, then close TCP on every exit path.
/// Callback errors and cancellation propagate unchanged. No heartbeat, reconnect,
/// or closeSession request is implemented yet; the server expires the session later.
pub async fn[T] with_client(
  options : ClientOptions,
  body : async (Client) -> T,
) -> T {
  validate_options(options)
  let mut connection : @socket.Tcp? = None
  defer (if connection is Some(socket) { socket.close() })
  let info = @async.with_timeout(
    options.request_timeout_ms,
    error=HandshakeTimeout,
    () => {
      let socket = @socket.Tcp::connect_to_host(
        options.endpoint.host,
        port=options.endpoint.port,
      )
      connection = Some(socket)
      establish_session(socket, options)
    },
  ) catch {
    ClientError::_ as error => raise error
    @moonkeeper.ProtocolError::_ as error => raise Protocol(error)
    error =>
      if @async.is_cancellation_error(error) {
        raise error
      } else {
        raise Transport(error.to_string())
      }
  }
  // Keep user code outside the transport error handler and handshake deadline.
  let client = Client::{
    info,
    socket: connection.unwrap(),
    lock: @async.Mutex::Mutex(),
    next_xid: 1,
    request_timeout_ms: options.request_timeout_ms,
    max_frame_size: options.max_frame_size,
    current_state: Connected,
  }
  defer client.close()
  body(client)
}
