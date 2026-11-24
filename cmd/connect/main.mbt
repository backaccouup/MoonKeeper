// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "--help" {
    println("Usage: moon run cmd/connect --target native -- [host] [port]")
    return
  }
  guard args.length() <= 3 else { fail("usage: connect [host] [port]") }
  let host = if args.length() > 1 { args[1] } else { "127.0.0.1" }
  let port = if args.length() > 2 { @string.parse_int(args[2]) } else { 2181 }
  let options = @client.ClientOptions::new(@client.Endpoint::new(host, port~))
  @client.with_client(options, client => {
    let info = client.session_info()
    println("ZooKeeper handshake succeeded at \{host}:\{port}")
    println("session_id=\{info.session_id}")
    println("session_timeout_ms=\{info.session_timeout_ms}")
    println("read_only=\{info.read_only}")
  })
  println(
    "TCP connection closed; heartbeats and closeSession are not implemented yet.",
  )
}
