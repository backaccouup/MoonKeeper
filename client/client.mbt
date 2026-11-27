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
/// Request timeout bounds connection establishment and each request.
/// The pending request and event limits apply per client.
pub(all) struct ClientOptions {
  endpoint : Endpoint
  fallback_endpoints : Array[Endpoint]
  reconnect : ReconnectPolicy?
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
  fallback_endpoints~ : Array[Endpoint] = [],
  reconnect~ : ReconnectPolicy? = None,
  session_timeout_ms~ : Int32 = 30000,
  request_timeout_ms~ : Int32 = 10000,
  max_frame_size~ : Int32 = 1048576,
  max_pending_requests~ : Int32 = 256,
  event_buffer_capacity~ : Int32 = 256,
  read_only~ : Bool = false,
) -> ClientOptions {
  {
    endpoint,
    fallback_endpoints,
    reconnect,
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
  priv mut info : SessionInfo
  priv mut socket : @socket.Tcp
  priv lock : @async.Mutex
  priv mut next_xid : Int32
  priv request_timeout_ms : Int32
  priv max_frame_size : Int32
  priv event_buffer_capacity : Int32
  priv mut buffered_events : Int32
  priv mut watches : Array[Watch]
  priv pending : Map[Int32, Pending]
  priv options : ClientOptions
  priv endpoints : Array[Endpoint]
  priv mut endpoint_index : Int32
  priv mut generation : Int32
  priv mut password : Bytes
  priv mut last_zxid : Int64
  priv group : @async.TaskGroup[Unit]
  priv mut recovery : @async.Task[Unit]?
  priv auth_frames : Array[Bytes]
  priv auth_lock : @async.Mutex
  priv mut state_stream_closed : Bool
  priv state_events : @aqueue.Queue[ClientState]
  priv mut last_receive_ms : Int64
  priv mut reader_task : @async.Task[Unit]?
  priv mut heartbeat_task : @async.Task[Unit]?
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
fn validate_options(options : ClientOptions) -> Unit raise ClientError {
  for endpoint in options.fallback_endpoints + [options.endpoint] {
    guard !endpoint.host.is_empty() &&
      !endpoint.host.contains("\u0000") &&
      endpoint.port > 0 &&
      endpoint.port <= 65535 else {
      raise InvalidOptions("invalid endpoint")
    }
  }
  if options.reconnect is Some(p) {
    guard p.attempts > 0 &&
      p.initial_delay_ms > 0 &&
      p.max_delay_ms >= p.initial_delay_ms &&
      p.max_delay_ms <= 60000 else {
      raise InvalidOptions("invalid reconnect policy")
    }
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
/// Session material stays private and is reused only for the same session.
pub async fn[T] with_client(
  options : ClientOptions,
  body : async (Client) -> T,
) -> T {
  validate_options(options)
  let endpoints = [options.endpoint] + options.fallback_endpoints
  let (index, socket, info, password) = open_initial(options, endpoints)
  defer socket.close()
  let mut result : T? = None
  @async.with_task_group(group => {
    let client = Client::{
      info,
      socket,
      group,
      endpoints,
      endpoint_index: index,
      generation: 0,
      options,
      password,
      last_zxid: 0L,
      pending: {},
      auth_frames: [],
      auth_lock: @async.Mutex::Mutex(),
      recovery: None,
      lock: @async.Mutex::Mutex(),
      next_xid: 1,
      request_timeout_ms: options.request_timeout_ms,
      max_frame_size: options.max_frame_size,
      event_buffer_capacity: options.event_buffer_capacity,
      buffered_events: 0,
      watches: [],
      state_stream_closed: false,
      state_events: @aqueue.Queue::Queue(
        kind=Blocking(options.event_buffer_capacity),
      ),
      last_receive_ms: @async.now(),
      reader_task: None,
      heartbeat_task: None,
      current_state: Connected,
    }
    client.start_io()
    defer (if @async.is_being_cancelled() {
      client.release_closed_client()
    } else {
      @async.protect_from_cancel(() => client.close())
    })
    result = Some(body(client))
  })
  result.unwrap()
}
