// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "real multi commits mixed operations and rolls back a bad middle check" {
  let host = @env.get_env_var("MOONKEEPER_ZK_HOST").unwrap_or("127.0.0.1")
  let port = match @env.get_env_var("MOONKEEPER_ZK_PORT") {
    Some(value) => @string.parse_int(value)
    None => fail("Set MOONKEEPER_ZK_PORT or run the integration script")
  }
  let options = @client.ClientOptions::new(@client.Endpoint::new(host, port~))
  @client.with_client(options, writer => {
    let base = "/moonkeeper-multi-\{writer.session_info().session_id}"
    let acl = @moonkeeper.open_acl_unsafe()
    let normal = @moonkeeper.CreateOptions::new(Persistent, acl)
    let sequential = @moonkeeper.CreateOptions::new(PersistentSequential, acl)
    ignore(writer.create(base, Some(b"old"), normal))
    @client.with_client(options, reader => {
      defer {
        for name in reader.get_children(base) {
          reader.delete(base + "/" + name, -1)
        }
        reader.delete(base, -1)
      }
      let removed = base + "/removed"
      ignore(writer.create(removed, None, normal))
      let prefix = base + "/item-"
      let outcome = writer.multi([
        Check(base, 0),
        Create(prefix, Some(b"\x00\xff"), sequential),
        SetData(base, Some(b"new"), 0),
        Delete(removed, -1),
      ])
      guard outcome
        is Committed([Checked, Created(path), DataSet(stat), Deleted]) else {
        fail("unexpected result order")
      }
      assert_true(path != prefix && path.has_prefix(prefix))
      assert_eq(reader.get_data(path).data, Some(b"\x00\xff"))
      let committed = reader.get_data(base)
      assert_eq(committed.data, Some(b"new"))
      assert_eq(committed.stat.version, 1)
      assert_eq(stat.mzxid, committed.stat.mzxid)
      assert_eq(stat.version, committed.stat.version)
      assert_eq(reader.exists(removed), None)
      let abort = writer.multi([
        SetData(base, Some(b"rolled back"), -1),
        Check(base, 99),
        Delete(path, -1),
      ])
      guard abort is Aborted(index, results) else {
        fail("expected BadVersion")
      }
      assert_eq(index, 1)
      assert_eq(results, [NotApplied(0), Failed(-103), NotApplied(-2)])
      assert_eq(reader.get_data(base), committed)
      assert_eq(reader.get_data(path).data, Some(b"\x00\xff"))
    })
  })
}
