// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn expect_no_auth(action : async () -> Unit) -> Unit {
  try {
    action()
    fail("expected NoAuth")
  } catch {
    @client.ClientError::Server(-102) => ()
    err => fail("unexpected access result \{err}")
  }
}

///|
#skip
async test "three real sessions enforce creator digest, ACL versions and permission changes" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT or run the integration script")
  }
  let options = @client.ClientOptions::new(@client.Endpoint::new(host, port~))
  let entropy = @random.Rand::Rand()
  @client.with_client(options, owner => {
    let path = "/moonkeeper-acl-\{owner.session_info().session_id}"
    owner.add_auth(
      "digest",
      @utf8.encode("owner:\{entropy.uint64()}\{entropy.uint64()}"),
    )
    // An ephemeral znode also cleans itself up if an assertion terminates the test.
    ignore(
      owner.create(
        path,
        Some(b"private"),
        @moonkeeper.CreateOptions::new(Ephemeral, @moonkeeper.creator_acl()),
      ),
    )
    let original = owner.get_acl(path)
    assert_eq(original.stat.aversion, 0)
    assert_eq(original.acl.length(), 1)
    assert_eq(original.acl[0].scheme, "digest")
    assert_true(original.acl[0].id.has_prefix("owner:"))
    assert_eq(original.acl[0].permissions, @moonkeeper.PERM_ALL)
    ignore(owner.set_data(path, Some(b"authorized"), 0))
    @client.with_client(options, anonymous => {
      @client.with_client(options, other => {
        other.add_auth(
          "digest",
          @utf8.encode("other:\{entropy.uint64()}\{entropy.uint64()}"),
        )
        for session in [anonymous, other] {
          expect_no_auth(() => ignore(session.get_data(path)))
          expect_no_auth(() => {
            ignore(session.set_data(path, Some(b"denied"), -1))
          })
        }
        let unchanged = owner.get_data(path)
        assert_eq(unchanged.data, Some(b"authorized"))
        assert_eq(unchanged.stat.version, 1)
        let proof = path + "-identity"
        ignore(
          other.create(
            proof,
            None,
            @moonkeeper.CreateOptions::new(Ephemeral, @moonkeeper.creator_acl()),
          ),
        )
        let other_identity = other.get_acl(proof).acl[0]
        other.delete(proof, -1)
        let updated = original.acl.copy()
        updated.push({ ..other_identity, permissions: @moonkeeper.PERM_READ, })
        let revised = owner.set_acl(path, updated, original.stat.aversion)
        assert_eq(revised.aversion, 1)
        try {
          ignore(owner.set_acl(path, original.acl, original.stat.aversion))
          fail("expected stale ACL version to fail")
        } catch {
          @client.ClientError::Server(-103) => ()
          err => fail("unexpected ACL version result \{err}")
        }
        assert_eq(owner.get_acl(path).acl, updated)
        assert_eq(other.get_data(path).data, Some(b"authorized"))
        expect_no_auth(() => ignore(anonymous.get_data(path)))
        expect_no_auth(() => ignore(other.set_data(path, Some(b"denied"), -1)))
        expect_no_auth(() => ignore(other.set_acl(path, updated, -1)))
        assert_eq(owner.get_data(path).stat.version, 1)
      })
    })
    owner.delete(path, -1)
  })
}
