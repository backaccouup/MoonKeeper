// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
/// An existence watch also covers the race in which a missing node is recreated.
async fn subscribe(
  client : @client.Client,
  path : String,
) -> (@moonkeeper.DataResult?, @client.Watch) {
  for ;; {
    let (value, watch) = client.watch_data(path) catch {
      @client.ClientError::Server(-101) => {
        let (stat, created) = client.watch_exists(path)
        if stat is None {
          return (None, created)
        }
        created.cancel()
        continue
      }
      error => raise error
    }
    return (Some(value), watch)
  }
}

///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 || args.length() == 3 else {
    fail("usage: config_watch PATH [SNAPSHOT_COUNT]")
  }
  let limit = if args.length() == 3 { @string.parse_int(args[2]) } else { 0 }
  guard limit >= 0 else { fail("snapshot count must be nonnegative") }
  let path = args[1]
  @client.with_client(@common.options(), client => {
    for count = 0 {
      @common.wait_connected(client)
      let (snapshot, watch) = subscribe(client, path) catch {
        error if client.state() is Disconnected ||
          error is @client.ClientError::Disconnected => {
          @io.Writer::write(
            @stdio.stderr, "disconnected; configuration is stale\n",
          )
          continue count
        }
        error => raise error
      }
      defer watch.cancel()
      if !(client.state() is Connected) {
        continue count
      }
      let line = match snapshot {
        Some(value) => {
          let payload = match value.data {
            Some(data) => @base64.encode(data)
            None => "(null)"
          }
          "version=\{value.stat.version} data=\{payload}"
        }
        None => "missing"
      }
      @io.Writer::write(@stdio.stdout, line + "\n")
      if limit > 0 && count + 1 >= limit {
        break
      }
      // A restored session is itself a reason to reread, even with no znode notification.
      @async.any([
        () => ignore(watch.next_event()),
        () => {
          if client.next_state_event() is Some(Disconnected) {
            @io.Writer::write(
              @stdio.stderr, "disconnected; configuration is stale\n",
            )
          }
        },
      ])
      continue count + 1
    }
  })
}
