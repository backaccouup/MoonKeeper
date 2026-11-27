// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "child queries use distinct opcodes and return names plus Stat" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      for
        (xid, op, body) in [
          (1, 8, int32_wire(0)),
          (
            2,
            12,
            int32_wire(2) +
            int32_wire(1) +
            b"b" +
            int32_wire(1) +
            b"a" +
            stat_fixture(3),
          ),
        ] {
        let size = match conn.read_exactly(4) {
          [i32be(n)] => n
          _ => fail("length")
        }
        let request = conn.read_exactly(size)
        assert_eq(request[0:8].to_owned(), int32_wire(xid) + int32_wire(op))
        let reply = @buffer.Buffer()
        reply.write_int_be(16 + body.length())
        reply.write_int_be(xid)
        reply.write_int64_be(1L)
        reply.write_int_be(0)
        reply.write_bytesview(body)
        conn.write(reply.to_bytes())
      }
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        assert_eq(client.get_children("/parent").length(), 0)
        let result = client.get_children_with_stat("/parent")
        assert_eq(result.children, ["b", "a"])
        assert_eq(result.stat.version, 3)
      })
    },
  )
}
