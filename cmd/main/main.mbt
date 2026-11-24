// Copyright 2026 Mr-Shi123
// SPDX-License-Identifier: Apache-2.0

///|
fn main raise {
  let request = @moonkeeper.encode_connect_request(30000)
  println("MoonKeeper offline handshake example")
  println(
    "New-session request: \{request.length()} bytes (including length prefix)",
  )

  // A synthetic wire fixture, not a response from a running server.
  let fixture = b"\x00\x00\x00\x25" +
    b"\x00\x00\x00\x00" +
    b"\x00\x00\x75\x30" +
    b"\x01\x02\x03\x04\x05\x06\x07\x08" +
    b"\x00\x00\x00\x10" +
    b"0123456789abcdef\x00"
  let response = @moonkeeper.decode_connect_response(fixture)
  println("Fixture protocol version: \{response.protocol_version}")
  println("Fixture timeout: \{response.session_timeout_ms} ms")
  println("Fixture session ID: \{response.session_id}")
  println("Fixture read-only: \{response.read_only}")
  println("No network connection was made.")
}
