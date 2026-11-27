// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
test "invalid commands and option values raise usage errors" {
  let bad : Array[Array[String]] = [
    [],
    ["get"],
    ["made-up", "/x"],
    ["set", "/x"],
    ["delete", "/x", "--version", "-2"],
    ["create", "/x", "--mode", "special"],
    ["create", "/x", "--text", "a", "--file", "b"],
    ["stat", "//bad"],
    ["children", "/", "--request-timeout", "0"],
    ["exists", "/", "--servers", "server:65536"],
    ["exists", "/", "--servers", "server:1,"],
  ]
  for argv in bad {
    try parse_args(argv) catch {
      Usage(_) => ()
    } noraise {
      _ => fail("invalid arguments accepted: \{argv.join(" ")}")
    }
  }
}

///|
test "server list, version and session timeout reach request settings" {
  guard parse_args([
      "--servers", "one:2222,[::1]:2182,two", "set", "/x", "--text", "", "--version",
      "-1", "--session-timeout", "4000",
    ])
    is Run(args) else {
    fail("expected command")
  }
  assert_eq(args.endpoints, [
    @client.Endpoint::new("one", port=2222),
    @client.Endpoint::new("::1", port=2182),
    @client.Endpoint::new("two"),
  ])
  assert_eq(args.version, -1)
  assert_eq(args.session_timeout, 4000)
  guard args.input is Text("") else { fail("expected an empty string") }
}

///|
async test "input file failure and incorrect credentials do not expose secrets" {
  try read_input(File("moonkeeper-file-that-does-not-exist/absent")) catch {
    Usage(_) => ()
    error => raise error
  } noraise {
    _ => fail("missing file accepted")
  }
  let fixture = "sensitive-fixture"
  try digest_credential(fixture) catch {
    Usage(message) => assert_false(message.contains(fixture))
  } noraise {
    _ => fail("malformed digest accepted")
  }
  assert_eq(digest_credential("name:pass word"), b"name:pass word")
}
