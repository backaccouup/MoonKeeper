// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// No variant includes session credentials or raw response bytes.
#derive(Debug)
pub suberror ClientError {
  InvalidOptions(String)
  Transport(String)
  HandshakeTimeout
  ConnectionClosed
  Protocol(@moonkeeper.ProtocolError)
  SessionRejected
  UnsupportedProtocol(Int32)
  InvalidSession(String)
  ReadOnlyNotAllowed
}

///|
pub extend ClientError with @debug.Debug::{to_repr}
