// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
fn setting(name : String) -> String raise {
  guard @env.get_env_var(name) is Some(value) else {
    fail("missing interop setting \{name}")
  }
  value
}

///|
async fn exchange(client : @client.Client, root : String) -> Unit {
  let seed = root + "/seed"
  let trigger = root + "/trigger"
  let initial = client.get_data(seed)
  assert_eq(initial.data, Some(b"\xf0\x00\xffK"))
  assert_eq(initial.stat.version, 0)
  assert_eq(initial.stat.data_length, 4)
  let acl = client.get_acl(seed)
  guard acl.acl is [entry] else { fail("expected one Kazoo ACL") }
  assert_true(
    entry.permissions == 31 &&
    entry.scheme == "digest" &&
    entry.id == setting("MOONKEEPER_INTEROP_ACL_ID"),
  )
  let (before, watch) = client.watch_data(trigger)
  assert_eq(before.stat.version, 0)
  let sequential = @moonkeeper.CreateOptions::new(
    PersistentSequential,
    @moonkeeper.creator_acl(),
  )
  let batch = client.multi([
    Check(seed, 0),
    SetData(seed, Some(b"\x00M\xff\x80"), 0),
    Create(root + "/member-", Some(b"\x99\x00"), sequential),
  ])
  guard batch is Committed([Checked, DataSet(stat), Created(path)]) else {
    fail("unexpected committed results")
  }
  assert_eq(stat.version, 1)
  let event = @async.with_timeout(10000, () => watch.next_event())
  guard event is Some(changed) else { fail("missing Kazoo watch event") }
  assert_eq(changed.path, trigger)
  assert_eq(changed.kind, @moonkeeper.WatchEventType::NodeDataChanged)
  let after = client.get_data(trigger)
  assert_eq(after.data, Some(b"\xfeK\x00"))
  assert_eq(after.stat.version, 1)
  assert_eq(client.get_data(root + "/ack").data, Some(b"\xfe\x00"))
  let aborted = client.multi([
    SetData(seed, Some(b"rollback"), -1),
    Check(seed, 99),
    Delete(path, -1),
  ])
  guard aborted is Aborted(1, [NotApplied(0), Failed(-103), NotApplied(-2)]) else {
    fail("unexpected rollback statuses")
  }
  println("\{path} \{stat.mzxid}")
}

///|
async fn lost_reply(client : @client.Client, root : String) -> Unit {
  let original = client.session_info().session_id
  let sequential = @moonkeeper.CreateOptions::new(
    PersistentSequential,
    @moonkeeper.creator_acl(),
  )
  try {
    ignore(client.multi([Create(root + "/lost-", None, sequential)]))
    fail("expected an unknown outcome")
  } catch {
    @client.ClientError::OutcomeUnknown => ()
    err => raise err
  }
  @async.with_timeout(10000, () => {
    while client.state() != Connected {
      guard client.next_state_event() is Some(state) &&
        (state is Disconnected || state is Connecting || state is Connected) else {
        fail("session ended during recovery")
      }
    }
  })
  assert_eq(client.session_info().session_id, original)
  assert_eq(client.get_data(root + "/seed").data, Some(b"\x00M\xff\x80"))
}

///|
async fn main {
  let root = setting("MOONKEEPER_INTEROP_ROOT")
  let host = setting("MOONKEEPER_ZK_HOST")
  let endpoint = @client.Endpoint::new(
    host,
    port=@string.parse_int(setting("MOONKEEPER_ZK_PORT")),
  )
  let credential = @utf8.encode(setting("MOONKEEPER_INTEROP_CREDENTIAL"))
  match @env.get_env_var("MOONKEEPER_INTEROP_PROXY_PORT") {
    None =>
      @client.with_client(@client.ClientOptions::new(endpoint), client => {
        client.add_auth("digest", credential)
        exchange(client, root)
      })
    Some(proxy_port) => {
      let proxy = @client.Endpoint::new(
        "127.0.0.1",
        port=@string.parse_int(proxy_port),
      )
      let options = @client.ClientOptions::new(
        proxy,
        fallback_endpoints=[endpoint],
        reconnect=Some(@client.ReconnectPolicy::new()),
      )
      @client.with_client(options, client => {
        client.add_auth("digest", credential)
        lost_reply(client, root)
      })
    }
  }
}
