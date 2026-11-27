// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
#skip
async test "keeper CLI binary round trip, cross-process watch and service discovery" {
  guard @env.get_env_var("MOONKEEPER_ZK_PORT") is Some(_) else {
    fail("set MOONKEEPER_ZK_PORT and build the native examples first")
  }
  let python = if @env.get_env_var("OS") == Some("Windows_NT") {
    "python"
  } else {
    "python3"
  }
  let (code, stdout, stderr) = @process.collect_output(python, [
    "integration/cli_scenarios.py",
  ])
  guard code == 0 else {
    fail("CLI scenarios exited \{code}\n\{stdout.text()}\n\{stderr.text()}")
  }
}
