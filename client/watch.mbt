// Copyright 2026 backaccouup
// SPDX-License-Identifier: Apache-2.0

///|
priv enum WatchKind {
  Exists
  Data
  Children
}

///|
/// A single local subscription. Cancel only stops local consumption; it does
/// not send removeWatches to ZooKeeper.
pub struct Watch {
  priv owner : Client
  priv path : String
  priv kind : WatchKind
  priv events : @aqueue.Queue[@moonkeeper.WatchEvent]
  priv mut active : Bool
  priv mut missing : Bool
  priv mut registered : Bool
  priv mut pending : Bool
  priv mut finished : Bool
}

///|
fn Client::new_watch(self : Client, path : String, kind : WatchKind) -> Watch {
  {
    owner: self,
    path,
    kind,
    events: @aqueue.Queue::Queue(kind=@aqueue.Kind::Blocking(1)),
    active: true,
    registered: false,
    missing: false,
    pending: false,
    finished: false,
  }
}

///|
fn Client::prune_watches(self : Client) -> Unit {
  let remaining : Array[Watch] = []
  for watch in self.watches {
    if watch.active {
      remaining.push(watch)
    }
  }
  self.watches = remaining
}

///|
fn Client::close_watches(self : Client) -> Unit {
  let old = self.watches
  self.watches = []
  for watch in old {
    watch.cancel()
  }
}

///|
pub fn Watch::cancel(self : Watch) -> Unit {
  if !self.finished {
    self.finished = true
    self.active = false
    if self.pending {
      self.pending = false
      self.owner.buffered_events -= 1
    }
    self.events.close(clear=true)
    self.owner.prune_watches()
  }
}

///|
pub async fn Watch::next_event(self : Watch) -> @moonkeeper.WatchEvent? {
  if self.finished {
    return None
  }
  let event = self.events.get() catch {
    @aqueue.QueueAlreadyClosed => {
      // Another waiter may already own the one buffered event. Do not let
      // this waiter invalidate that event before its owner resumes.
      if !self.pending {
        self.finished = true
      }
      return None
    }
    ClientError::WatchOverflow => {
      self.finished = true
      raise ClientError::WatchOverflow
    }
    error => raise error
  }
  if self.pending {
    self.pending = false
    self.owner.buffered_events -= 1
  }
  if self.finished {
    return None
  }
  self.finished = true
  Some(event)
}

///|
fn Watch::accepts(self : Watch, event : @moonkeeper.WatchEvent) -> Bool {
  if !self.active || !self.registered || self.path != event.path {
    return false
  }
  match self.kind {
    Exists =>
      event.kind is @moonkeeper.WatchEventType::NodeCreated ||
      event.kind is @moonkeeper.WatchEventType::NodeDeleted ||
      event.kind is @moonkeeper.WatchEventType::NodeDataChanged
    Data =>
      event.kind is @moonkeeper.WatchEventType::NodeDeleted ||
      event.kind is @moonkeeper.WatchEventType::NodeDataChanged
    Children =>
      event.kind is @moonkeeper.WatchEventType::NodeDeleted ||
      event.kind is @moonkeeper.WatchEventType::NodeChildrenChanged
  }
}

///|
fn Watch::activate(self : Watch) -> Unit {
  if !self.active {
    return
  }
  self.registered = true
}

///|
fn Watch::deliver(self : Watch, event : @moonkeeper.WatchEvent) -> Unit {
  if !self.active {
    return
  }
  self.active = false
  if self.owner.buffered_events >= self.owner.event_buffer_capacity ||
    !(self.events.try_put(event) catch { _ => false }) {
    self.events.close(error=ClientError::WatchOverflow, clear=true)
    return
  }
  self.owner.buffered_events += 1
  self.pending = true
  self.events.close()
}

///|
pub async fn Client::watch_exists(
  self : Client,
  path : String,
) -> (@moonkeeper.Stat?, Watch) {
  let watch = self.new_watch(path, Exists)
  errdefer watch.cancel()
  let result = self.request(
    xid => @moonkeeper.encode_watch_exists_request(xid, path),
    payload => @moonkeeper.decode_exists_response(payload),
    false,
    watch=Some(watch),
  )
  (result, watch)
}

///|
pub async fn Client::watch_data(
  self : Client,
  path : String,
) -> (@moonkeeper.DataResult, Watch) {
  let watch = self.new_watch(path, Data)
  errdefer watch.cancel()
  let result = self.request(
    xid => @moonkeeper.encode_watch_data_request(xid, path),
    payload => @moonkeeper.decode_get_data_response(payload),
    false,
    watch=Some(watch),
  )
  (result, watch)
}

///|
pub async fn Client::watch_children(
  self : Client,
  path : String,
) -> (@moonkeeper.ChildrenResult, Watch) {
  let watch = self.new_watch(path, Children)
  errdefer watch.cancel()
  let result = self.request(
    xid => @moonkeeper.encode_watch_children_request(xid, path),
    payload => @moonkeeper.decode_get_children_with_stat_response(payload),
    false,
    watch=Some(watch),
  )
  (result, watch)
}

///|
pub async fn Client::next_state_event(self : Client) -> ClientState? {
  let state = self.state_events.get() catch {
    @aqueue.QueueAlreadyClosed => return None
    error => raise error
  }
  Some(state)
}
