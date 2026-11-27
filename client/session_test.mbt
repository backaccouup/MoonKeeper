///|
async test "multiple requests reach the wire and out of order replies match xid" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      for expected in [1, 2] {
        guard conn.read_exactly(4) is [i32be(size)] else { fail("length") }
        guard conn.read_exactly(size) is [i32be(xid), ..] else { fail("xid") }
        assert_eq(xid, expected)
      }
      conn.write(watched_reply(2, -101) + watched_reply(1, -101))
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        @async.with_task_group(group => {
          let first = group.spawn(() => client.exists("/a"))
          let second = group.spawn(() => client.exists("/b"))
          assert_eq(first.wait(), None)
          assert_eq(second.wait(), None)
        })
      })
    },
  )
}
