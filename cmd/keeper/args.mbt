// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
suberror Usage {
  Usage(String)
}

///|
priv enum Input {
  Null
  Text(String)
  File(String)
}

///|
priv enum Action {
  Exists
  Get
  Set
  Create
  Delete
  Children
  Watch
  Stat
}

///|
priv enum WatchKind {
  Exists
  Data
  Children
}

///|
priv struct Args {
  action : Action
  path : String
  endpoints : Array[@client.Endpoint]
  request_timeout : Int32
  session_timeout : Int32
  version : Int32
  mode : @moonkeeper.CreateMode
  watch_kind : WatchKind
  input : Input
  output : String?
  auth_file : String?
}

///|
priv enum CommandLine {
  Help(String)
  Run(Args)
}

///|
fn schema() -> @argparse.Command {
  let path = @argparse.PositionArg(
    "path",
    num_args=@argparse.ValueRange::single(),
  )
  let text = @argparse.OptionArg(
    "text",
    about="Write UTF-8 text.",
    allow_hyphen_values=true,
    conflicts_with=["file", "null"],
  )
  let file = @argparse.OptionArg(
    "file",
    about="Read binary data from a file.",
    conflicts_with=["null"],
  )
  let null_data = @argparse.FlagArg("null", about="Write a null data buffer.")
  let version = @argparse.OptionArg(
    "version",
    about="Expected data version (-1 accepts any).",
    allow_hyphen_values=true,
  )
  @argparse.Command(
    "keeper",
    about="ZooKeeper native client",
    subcommand_required=true,
    options=[
      @argparse.OptionArg(
        "servers",
        global=true,
        about="Comma-separated host[:port] list (default 127.0.0.1:2181).",
      ),
      @argparse.OptionArg(
        "request-timeout",
        global=true,
        about="Request deadline in ms (default 10000).",
      ),
      @argparse.OptionArg(
        "session-timeout",
        global=true,
        about="Requested session timeout in ms (default 30000).",
      ),
      @argparse.OptionArg(
        "auth-file",
        global=true,
        about="UTF-8 user:password file. Takes precedence over MOONKEEPER_DIGEST.",
      ),
    ],
    subcommands=[
      @argparse.Command("exists", about="Print true or false.", positionals=[
        path,
      ]),
      @argparse.Command(
        "get",
        about="Print Base64 or (null).",
        positionals=[path],
        options=[
          @argparse.OptionArg("output", about="Write raw bytes to a file."),
        ],
      ),
      @argparse.Command(
        "set",
        about="Update data with --text, --file or --null.",
        positionals=[path],
        flags=[null_data],
        options=[text, file, version],
      ),
      @argparse.Command(
        "create",
        about="Create a node with open ACL; default data is null.",
        positionals=[path],
        flags=[null_data],
        options=[
          text,
          file,
          @argparse.OptionArg(
            "mode",
            about="persistent (default), ephemeral, persistent-sequential, ephemeral-sequential.",
          ),
        ],
      ),
      @argparse.Command("delete", about="Delete a node.", positionals=[path], options=[
        version,
      ]),
      @argparse.Command("children", about="List child names, one per line.", positionals=[
        path,
      ]),
      @argparse.Command(
        "watch",
        about="Wait for one notification.",
        positionals=[path],
        options=[
          @argparse.OptionArg(
            "kind",
            about="exists (default), data or children.",
          ),
        ],
      ),
      @argparse.Command("stat", about="Print node metadata.", positionals=[path]),
    ],
  )
}

///|
fn number(
  value : StringView,
  name : String,
  minimum : Int32,
) -> Int32 raise Usage {
  let n = @string.parse_int(value, base=10) catch {
    _ => raise Usage("invalid integer for " + name)
  }
  guard n >= minimum else { raise Usage(name + " is out of range") }
  n
}

///|
fn parse_servers(value : String) -> Array[@client.Endpoint] raise Usage {
  let endpoints = []
  for item in value.split(",") {
    let (host, port) = if item.strip_prefix("[") is Some(rest) {
      guard rest.split_once("]") is Some((host, suffix)) else {
        raise Usage("invalid bracketed server address")
      }
      let port = if suffix.is_empty() {
        2181
      } else {
        guard suffix.strip_prefix(":") is Some(port) else {
          raise Usage("expected a port after ']'")
        }
        number(port, "port", 1)
      }
      (host, port)
    } else {
      match item.split_once(":") {
        Some((name, value)) => (name, number(value, "port", 1))
        None => (item, 2181)
      }
    }
    guard !host.is_empty() &&
      !host.contains_any(chars="[]/ \t\r\n\u0000") &&
      port <= 65535 else {
      raise Usage("invalid server address or port")
    }
    endpoints.push(@client.Endpoint::new(host.to_owned(), port~))
  }
  guard !endpoints.is_empty() else { raise Usage("empty server list") }
  endpoints
}

///|
fn arg(matches : @argparse.Matches, key : String) -> String? {
  match matches.values.get(key) {
    Some([value]) => Some(value)
    _ => None
  }
}

///|
fn parse_args(argv : ArrayView[String]) -> CommandLine raise Usage {
  let matches = match schema().parse_outcome(argv~) {
    Parsed(matches) => matches
    Help(text) | Version(text) => return Help(text)
    Failed(_) =>
      raise Usage(
        "invalid arguments; run keeper --help or keeper COMMAND --help",
      )
  }
  guard matches.subcommand is Some((command, opts)) &&
    arg(opts, "path") is Some(path) else {
    raise Usage("expected a command and path")
  }
  let action : Action = match command {
    "exists" => Exists
    "get" => Get
    "set" => Set
    "create" => Create
    "delete" => Delete
    "children" => Children
    "watch" => Watch
    "stat" => Stat
    _ => raise Usage("unknown command")
  }
  let mode : @moonkeeper.CreateMode = match
    arg(opts, "mode").unwrap_or("persistent") {
    "persistent" => Persistent
    "ephemeral" => Ephemeral
    "persistent-sequential" => PersistentSequential
    "ephemeral-sequential" => EphemeralSequential
    _ => raise Usage("invalid create mode")
  }
  try {
    if action is Create {
      @moonkeeper.validate_create_path(
        path,
        mode is PersistentSequential || mode is EphemeralSequential,
      )
    } else {
      @moonkeeper.validate_path(path)
    }
  } catch {
    _ => raise Usage("invalid ZooKeeper path")
  }
  let input : Input = match (arg(opts, "text"), arg(opts, "file")) {
    (Some(s), None) => Text(s)
    (None, Some(f)) => File(f)
    (None, None) if !(action is Set) || opts.flags.get("null") == Some(true) =>
      Null
    _ => raise Usage("choose one of --text, --file or --null")
  }
  let watch_kind : WatchKind = match arg(opts, "kind").unwrap_or("exists") {
    "exists" => Exists
    "data" => Data
    "children" => Children
    _ => raise Usage("invalid watch kind")
  }
  Run({
    action,
    path,
    mode,
    watch_kind,
    input,
    endpoints: parse_servers(arg(opts, "servers").unwrap_or("127.0.0.1:2181")),
    request_timeout: number(
      arg(opts, "request-timeout").unwrap_or("10000")[:],
      "request timeout",
      1,
    ),
    session_timeout: number(
      arg(opts, "session-timeout").unwrap_or("30000")[:],
      "session timeout",
      1,
    ),
    version: number(arg(opts, "version").unwrap_or("-1")[:], "version", -1),
    output: arg(opts, "output"),
    auth_file: arg(opts, "auth-file"),
  })
}
