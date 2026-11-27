// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "multi rejects empty and oversized batches before writing, lost reply is unknown" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      let size = match conn.read_exactly(4) {
        [i32be(n)] => n
        _ => fail("missing frame length")
      }
      let wire = conn.read_exactly(size)
      assert_eq(wire[:8].to_owned(), int32_wire(1) + int32_wire(14))
      assert_eq(size, 36)
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(endpoint, max_frame_size=48),
        client => {
          try {
            ignore(client.multi([]))
            fail("empty transaction accepted")
          } catch {
            @client.ClientError::Protocol(
              @moonkeeper.ProtocolError::InvalidMulti(_)
            ) => ()
            err => raise err
          }
          try {
            ignore(client.multi([Check("/x", -1), Check("/x", -1)]))
            fail("aggregate frame limit ignored")
          } catch {
            @client.ClientError::Protocol(
              @moonkeeper.ProtocolError::FrameTooLarge(_)
            ) => ()
            err => raise err
          }
          try {
            ignore(client.multi([Delete("/x", -1)]))
            fail("lost response reported as a known outcome")
          } catch {
            @client.ClientError::OutcomeUnknown => ()
            err => raise err
          }
        },
      )
    },
  )
}
