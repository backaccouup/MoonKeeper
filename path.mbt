// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
pub fn validate_path(path : String) -> Unit raise ProtocolError {
  guard path.has_prefix("/") else { raise InvalidPath(path) }
  if path == "/" {
    return
  }
  guard !path.has_suffix("/") && !path.contains("//") else {
    raise InvalidPath(path)
  }
  for part in path.split("/") {
    guard part != "." && part != ".." else { raise InvalidPath(path) }
  }
  for char in path {
    let code = char.to_int()
    guard code > 31 &&
      code != 127 &&
      !(code >= 128 && code <= 159) &&
      !(code >= 0xd800 && code <= 0xf8ff) &&
      !(code >= 0xfff0 && code <= 0xffff) else {
      raise InvalidPath(path)
    }
  }
}
