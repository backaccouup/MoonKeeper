// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn main {
  let args = @env.args()
  guard args.length() == 3 else {
    fail("usage: service_registration PARENT SERVICE_ADDRESS")
  }
  let parent = args[1]
  @moonkeeper.validate_path(parent)
  let data = @utf8.encode(args[2])
  @client.with_client(@common.options(), client => {
    let owner = client.session_info().session_id
    let prefix = if parent == "/" { "" } else { parent }
    let path = "\{prefix}/instance-\{owner}"
    let opts = @moonkeeper.CreateOptions::new(
      Ephemeral,
      @moonkeeper.open_acl_unsafe(),
    )
    try client.create(path, Some(data), opts) catch {
      @client.ClientError::OutcomeUnknown => {
        // A deterministic path lets the same session check ownership and content.
        // Reading back an absent or different node cannot confirm this registration.
        @common.wait_connected(client)
        let entry = client.get_data(path)
        guard entry.stat.ephemeral_owner == owner && entry.data == Some(data) else {
          fail("could not confirm this session's registration")
        }
      }
      error => raise error
    } noraise {
      _ => ()
    }
    @io.Writer::write(@stdio.stdout, "registered \{path}\n")
    // EOF or Enter gracefully ends the scope. A terminal session also stops the service.
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        while client.next_state_event() is Some(state) {
          match state {
            Expired => fail("registration lost: session expired")
            AuthFailed | Closed => fail("registration lost: session ended")
            Disconnected =>
              @io.Writer::write(
                @stdio.stderr, "disconnected; registration unconfirmed\n",
              )
            _ => ()
          }
        }
      })
      ignore(@io.Reader::read_until(@stdio.stdin, "\n"))
    })
  })
}
