// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
async fn read_input(input : Input) -> Bytes? {
  match input {
    Null => None
    Text(text) => Some(@utf8.encode(text))
    File(path) => {
      let data = @fs.read_file(path) catch {
        _ => raise Usage("cannot read input file")
      }
      Some(data.binary())
    }
  }
}

///|
fn digest_credential(value : String) -> Bytes raise Usage {
  guard value.split_once(":") is Some((user, pass)) &&
    !user.is_empty() &&
    !pass.is_empty() &&
    !value.contains_any(chars="\r\n\u0000") else {
    raise Usage("digest credentials must contain one user:password line")
  }
  @utf8.encode(value)
}

///|
async fn credentials(path : String?) -> Bytes? {
  if path is Some(file) {
    let data = @fs.read_file(file) catch {
      _ => raise Usage("cannot read credential file")
    }
    let value = @utf8.decode(data.binary()) catch {
      _ => raise Usage("credential file must be UTF-8")
    }
    let line = match value.strip_suffix("\r\n") {
      Some(line) => line
      None => value.strip_suffix("\n").unwrap_or(value[:])
    }
    return Some(digest_credential(line.to_owned()))
  }
  match @env.get_env_var("MOONKEEPER_DIGEST") {
    Some(value) => Some(digest_credential(value))
    None => None
  }
}

///|
async fn execute(args : Args) -> Unit {
  let data = read_input(args.input)
  let auth = credentials(args.auth_file)
  let options = @client.ClientOptions::new(
    args.endpoints[0],
    fallback_endpoints=args.endpoints[1:].to_owned(),
    reconnect=Some(@client.ReconnectPolicy::new()),
    request_timeout_ms=args.request_timeout,
    session_timeout_ms=args.session_timeout,
  )
  @client.with_client(options, client => {
    if auth is Some(credential) {
      client.add_auth("digest", credential)
    }
    let path = args.path
    match args.action {
      Exists => println(client.exists(path) is Some(_))
      Get => {
        let value = client.get_data(path).data
        match (args.output, value) {
          (Some(out), Some(bytes)) =>
            @fs.write_file(out, bytes, create_mode=CreateOrTruncate)
          (Some(_), None) => fail("node data is null; no bytes to write")
          (None, Some(bytes)) => println(@base64.encode(bytes))
          (None, None) => println("(null)")
        }
      }
      Set =>
        println("version=\{client.set_data(path, data, args.version).version}")
      Create => {
        let opts = @moonkeeper.CreateOptions::new(
          args.mode,
          @moonkeeper.open_acl_unsafe(),
        )
        println(client.create(path, data, opts))
      }
      Delete => client.delete(path, args.version)
      Children =>
        for child in client.get_children(path) {
          println(child)
        }
      Watch => {
        let watch = match args.watch_kind {
          Exists => client.watch_exists(path).1
          Data => client.watch_data(path).1
          Children => client.watch_children(path).1
        }
        defer watch.cancel()
        @io.Writer::write(@stdio.stderr, "watch armed\n")
        guard watch.next_event() is Some(event) else {
          fail("watch ended before an event")
        }
        let kind = match event.kind {
          NodeCreated => "NodeCreated"
          NodeDeleted => "NodeDeleted"
          NodeDataChanged => "NodeDataChanged"
          NodeChildrenChanged => "NodeChildrenChanged"
        }
        println("\{kind} \{event.path}")
      }
      Stat => {
        guard client.exists(path) is Some(s) else {
          fail("node does not exist")
        }
        println("czxid=\{s.czxid}\nmzxid=\{s.mzxid}\npzxid=\{s.pzxid}")
        println("ctime=\{s.ctime}\nmtime=\{s.mtime}\nversion=\{s.version}")
        println("cversion=\{s.cversion}\naversion=\{s.aversion}")
        println(
          "ephemeralOwner=\{s.ephemeral_owner}\ndataLength=\{s.data_length}\nnumChildren=\{s.num_children}",
        )
      }
    }
  })
}

///|
async fn main {
  try {
    match parse_args(@env.args()[1:]) {
      Help(help) => println(help)
      Run(args) => execute(args)
    }
  } catch {
    Usage(message) => {
      @io.Writer::write(@stdio.stderr, "keeper: \{message}\n")
      @env.exit(2)
    }
    error => {
      if @async.is_cancellation_error(error) {
        raise error
      }
      @io.Writer::write(@stdio.stderr, "keeper: \{error}\n")
      @env.exit(1)
    }
  }
}
