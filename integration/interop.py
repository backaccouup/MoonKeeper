"""Run the MoonKeeper/Kazoo cross-client checks against an existing ZooKeeper."""

import json
import os
from pathlib import Path
from queue import Empty, Queue
import re
import secrets
import socket
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from uuid import uuid4

from kazoo.client import KazooClient
from kazoo.protocol.states import EventType
from kazoo.retry import KazooRetry
from kazoo.security import make_digest_acl


REPO = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def build_peer():
    result = subprocess.run(
        ["moon", "build", "integration/interop_peer", "--target", "native",
         "--deny-warn", "--output-json"],
        cwd=REPO, stdout=subprocess.PIPE, timeout=120,
    )
    if result.returncode:
        sys.stderr.buffer.write(result.stdout)
        result.check_returncode()
    for line in result.stdout.splitlines():
        if line.startswith(b"{"):
            record = json.loads(line)
            if record.get("$message_type") == "artifact":
                return record["path"]
    raise RuntimeError("moon build did not report the interop executable")


def run_peer(executable, env):
    return subprocess.run(
        [executable], env=env, cwd=REPO, timeout=30, check=True,
        stdout=subprocess.PIPE, text=True, encoding="utf-8",
    ).stdout.strip()


def check_exchange(zk, root, acl, executable, env):
    seed = root + "/seed"
    trigger = root + "/trigger"
    zk.create(seed, b"\xf0\x00\xffK", acl)
    zk.create(trigger, b"", acl)
    events = Queue()
    zk.get(seed, watch=events.put)
    with ThreadPoolExecutor(max_workers=1) as worker:
        peer = worker.submit(run_peer, executable, env)
        try:
            event = events.get(timeout=15)
        except Empty:
            if peer.done():
                peer.result()
            raise AssertionError("timed out waiting for MoonKeeper to change the seed")
        check((event.type, event.path) == (EventType.CHANGED, seed), "wrong watch event")
        data, stat = zk.get(seed)
        check((data, stat.version) == (b"\x00M\xff\x80", 1), "incorrect seed update")
        txn = zk.transaction()
        txn.check(seed, version=1)
        txn.set_data(trigger, b"\xfeK\x00", version=0)
        txn.create(root + "/ack", b"\xfe\x00", acl=acl)
        results = txn.commit()
        check(results[0] is True and results[1].version == 1 and
              results[2] == root + "/ack", "Kazoo transaction failed")
        path, zxid = peer.result().split()
    check(re.fullmatch(re.escape(root) + r"/member-[0-9]{10}", path), "invalid sequence path")
    check(int(zxid) == stat.mzxid, "clients disagree on the setData zxid")
    child, child_stat = zk.get(path)
    check(child == b"\x99\x00" and child_stat.czxid == stat.mzxid,
          "transaction writes did not share a zxid")
    check(zk.get_acls(path)[0] == acl, "MoonKeeper creator ACL differs from Kazoo digest ACL")
    check(zk.get(seed) == (data, stat), "aborted transaction changed seed data or Stat")


def receive_frame(stream):
    header = stream.read(4)
    if len(header) != 4:
        raise EOFError("missing test relay frame header")
    size, = struct.unpack("!i", header)
    if not 0 <= size <= 1048576:
        raise ValueError("invalid test relay frame size")
    payload = stream.read(size)
    if len(payload) != size:
        raise EOFError("incomplete test relay frame")
    return header + payload


def drop_multi_reply(listener, server):
    """Forward this peer's handshake and auth, then close after a real multi reply."""
    downstream, _ = listener.accept()
    with downstream, socket.create_connection(server, timeout=10) as upstream:
        downstream.settimeout(10)
        with downstream.makefile("rb") as requests, upstream.makefile("rb") as replies:
            upstream.sendall(receive_frame(requests))
            downstream.sendall(receive_frame(replies))
            while True:
                request = receive_frame(requests)
                xid, opcode = struct.unpack_from("!ii", request, 4)
                upstream.sendall(request)
                while True:
                    reply = receive_frame(replies)
                    reply_xid, _, err = struct.unpack_from("!iqi", reply, 4)
                    if reply_xid == xid and opcode == 14:
                        check(err == 0, "ZooKeeper rejected the multi request")
                        return
                    downstream.sendall(reply)
                    if reply_xid == xid:
                        break


def check_lost_reply(zk, root, executable, env, server):
    with socket.socket() as listener, ThreadPoolExecutor(max_workers=1) as worker:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(15)
        port = str(listener.getsockname()[1])
        relay = worker.submit(drop_multi_reply, listener, server)
        run_peer(executable, {**env, "MOONKEEPER_INTEROP_PROXY_PORT": port})
        relay.result()
    creations = [name for name in zk.get_children(root) if name.startswith("lost-")]
    check(len(creations) == 1, "expected exactly one committed sequential creation")


def main():
    host = os.environ.get("MOONKEEPER_ZK_HOST", "127.0.0.1")
    port = int(os.environ.get("MOONKEEPER_ZK_PORT", "21819"))
    executable = build_peer()
    root = "/moonkeeper-interop-" + uuid4().hex
    user = "interop"
    password = secrets.token_hex(24)
    credential = f"{user}:{password}"
    acl = [make_digest_acl(user, password, all=True)]
    env = {
        **os.environ, "MOONKEEPER_ZK_HOST": host, "MOONKEEPER_ZK_PORT": str(port),
        "MOONKEEPER_INTEROP_ROOT": root, "MOONKEEPER_INTEROP_CREDENTIAL": credential,
        "MOONKEEPER_INTEROP_ACL_ID": acl[0].id.id,
    }
    env.pop("MOONKEEPER_INTEROP_PROXY_PORT", None)
    authority = f"[{host}]" if ":" in host else host
    zk = KazooClient(
        hosts=f"{authority}:{port}", timeout=5,
        connection_retry=KazooRetry(max_tries=2, deadline=6),
        auth_data=[("digest", credential)],
    )
    try:
        zk.start(timeout=8)
        zk.create(root, b"", acl)
        try:
            check_exchange(zk, root, acl, executable, env)
            check_lost_reply(zk, root, executable, env, (host, port))
        finally:
            zk.delete(root, recursive=True)
    finally:
        zk.stop()
        zk.close()
    print("Kazoo interop passed, including committed multi with its reply dropped.")


if __name__ == "__main__":
    main()
