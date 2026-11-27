// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async test "256 outstanding requests bound application admission until replies arrive" {
  let received : @aqueue.Queue[Bool] = @aqueue.Queue::Queue(kind=Blocking(1))
  let proceed : @aqueue.Queue[Bool] = @aqueue.Queue::Queue(kind=Blocking(1))
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      for id in 1..<=256 {
        guard conn.read_exactly(4) is [i32be(size)] else { fail("length") }
        guard conn.read_exactly(size) is [i32be(xid), ..] else { fail("xid") }
        assert_eq(xid, id)
      }
      received.put(true)
      ignore(proceed.get())
      for id in 1..<=256 {
        conn.write(watched_reply(id, -101))
      }
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        @async.with_task_group(group => {
          for _ in 0..<256 {
            group.spawn_bg(() => assert_eq(client.exists("/x"), None))
          }
          ignore(received.get())
          try {
            ignore(client.exists("/excess"))
            fail("expected QueueFull")
          } catch {
            @client.ClientError::QueueFull => ()
            e => raise e
          }
          proceed.put(true)
        })
      })
    },
  )
}

///|
async test "a reconnectable watch must fit a single setWatches frame" {
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      watched_request(conn, 1, 3)
      conn.write(watched_reply(1, -101))
    },
    endpoint => {
      @client.with_client(
        @client.ClientOptions::new(
          endpoint,
          max_frame_size=45,
          reconnect=Some(@client.ReconnectPolicy::new()),
        ),
        client => {
          try {
            ignore(client.watch_exists("/1234567890123456789"))
            fail("oversized recovery frame accepted")
          } catch {
            @client.ClientError::InvalidOptions(_) => ()
            e => raise e
          }
          let (_, watch) = client.watch_exists("/short")
          watch.cancel()
        },
      )
    },
  )
}

///|
async test "explicit close sends the closeSession opcode and releases outstanding requests" {
  let ready : @aqueue.Queue[Bool] = @aqueue.Queue::Queue(kind=Blocking(1))
  let closed : @aqueue.Queue[Bool] = @aqueue.Queue::Queue(kind=Blocking(1))
  with_peer(
    conn => {
      ignore(conn.read_exactly(49))
      conn.write(fixture())
      guard conn.read_exactly(4) is [i32be(size)] else { fail("length") }
      ignore(conn.read_exactly(size))
      ready.put(true)
      assert_eq(
        conn.read_exactly(12),
        int32_wire(8) + int32_wire(2) + int32_wire(-11),
      )
      closed.put(true)
    },
    endpoint => {
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        @async.with_task_group(group => {
          let waiting = group.spawn(() => {
            try {
              ignore(client.exists("/x"))
              false
            } catch {
              @client.ClientError::Closed => true
              _ => false
            }
          })
          ignore(ready.get())
          client.close()
          assert_true(waiting.wait())
          ignore(closed.get())
          client.close()
        })
      })
    },
  )
}
