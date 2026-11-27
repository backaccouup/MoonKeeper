#!/usr/bin/env python3
"""Run the MoonKeeper recovery probe against three disposable ZooKeeper peers."""

import argparse
from contextlib import ExitStack, contextmanager
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
HIDDEN = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def local_ports(count):
    with ExitStack() as stack:
        sockets = [stack.enter_context(socket.socket()) for _ in range(count)]
        for sock in sockets:
            sock.bind((HOST, 0))
        return [sock.getsockname()[1] for sock in sockets]


def stop_process(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def build_probe():
    result = subprocess.run(
        ["moon", "build", "integration/recovery_probe", "--target", "native",
         "--release", "--deny-warn", "--output-json"],
        cwd=ROOT, timeout=180, stdout=subprocess.PIPE,
    )
    if result.returncode:
        sys.stderr.buffer.write(result.stdout)
        result.check_returncode()
    for line in result.stdout.splitlines():
        if line.startswith(b"{"):
            record = json.loads(line)
            if record.get("$message_type") == "artifact":
                return Path(record["path"])
    raise RuntimeError("moon build did not return the recovery probe executable")


@contextmanager
def java_cluster(zk_home, temp, ports):
    archive = zk_home / "lib/zookeeper-3.9.3.jar"
    if not archive.is_file():
        raise RuntimeError(f"ZooKeeper 3.9.3 binary distribution required at {zk_home}")
    java = shutil.which("java")
    if not java:
        raise RuntimeError("java is required for the Java backend")
    classpath = os.pathsep.join(str(p) for p in [zk_home / "conf", zk_home / "lib/*"])
    servers = "".join(
        f"server.{i + 1}={HOST}:{ports[3 + i]}:{ports[6 + i]};{HOST}:{ports[i]}\n"
        for i in range(3)
    )
    peers = []
    with ExitStack() as stack:
        for i in range(3):
            peer = temp / f"peer{i + 1}"
            data = peer / "data"
            data.mkdir(parents=True)
            (data / "myid").write_text(f"{i + 1}\n", encoding="ascii")
            config = peer / "zoo.cfg"
            config.write_text(
                f"dataDir={data.as_posix()}\ntickTime=1000\ninitLimit=10\nsyncLimit=5\n"
                "standaloneEnabled=false\nadmin.enableServer=false\n"
                "4lw.commands.whitelist=srvr\n" + servers,
                encoding="utf-8",
            )
            log = stack.enter_context((peer / "peer.log").open("wb"))
            proc = subprocess.Popen(
                [java, "-Xms32m", "-Xmx128m", "-XX:ActiveProcessorCount=2",
                 "-cp", classpath, "org.apache.zookeeper.server.quorum.QuorumPeerMain",
                 str(config)],
                cwd=peer, stdout=log, stderr=subprocess.STDOUT, creationflags=HIDDEN,
            )
            stack.callback(stop_process, proc)
            peers.append(proc)
        yield lambda peer_index: stop_process(peers[peer_index])


@contextmanager
def docker_cluster(ports, project):
    if not shutil.which("docker"):
        raise RuntimeError("install Docker Compose or set ZOOKEEPER_HOME to ZooKeeper 3.9.3")
    env = os.environ.copy()
    env.update({f"MOONKEEPER_PEER{i + 1}_PORT": str(p) for i, p in enumerate(ports[:3])})
    command = ["docker", "compose", "-p", project, "-f",
               str(ROOT / "integration/compose.cluster.yaml")]

    def run(*args, timeout=45):
        subprocess.run(command + list(args), env=env, timeout=timeout, check=True)

    try:
        run("up", "-d", timeout=180)
        yield lambda peer_index: run("kill", "-s", "SIGKILL", f"zk{peer_index + 1}")
    finally:
        run("down", "--volumes", "--remove-orphans")


def peer_role(port):
    try:
        with socket.create_connection((HOST, port), timeout=0.5) as connection:
            connection.sendall(b"srvr")
            with connection.makefile("rb") as response:
                for line in response:
                    if line.startswith(b"Mode: "):
                        return line[6:].strip()
    except OSError:
        pass
    return b""


def wait_for_quorum(ports):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        roles = [peer_role(port) for port in ports]
        if roles.count(b"leader") == 1 and roles.count(b"follower") == 2:
            return
        time.sleep(0.2)
    raise RuntimeError(f"ensemble readiness timed out, last roles {roles}")


def wait_for_signal(directory, marker, probe):
    deadline = time.monotonic() + 35
    while not (directory / marker).is_file():
        if probe.poll() is not None:
            raise RuntimeError(f"recovery probe exited with {probe.returncode} before {marker}")
        if time.monotonic() >= deadline:
            raise RuntimeError(f"recovery probe timed out waiting for {marker}")
        time.sleep(0.05)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["auto", "java", "docker"], default="auto")
    args = parser.parse_args()
    default_home = ROOT / "_build/apache-zookeeper-3.9.3-bin"
    zk_home = Path(os.environ.get("ZOOKEEPER_HOME", default_home)).resolve()
    use_java = args.backend == "java" or (
        args.backend == "auto" and (zk_home.is_dir() or "ZOOKEEPER_HOME" in os.environ)
    )
    probe_binary = build_probe()
    ports = local_ports(9)
    with tempfile.TemporaryDirectory(prefix="moonkeeper-cluster-") as name:
        directory = Path(name)
        cluster = (java_cluster(zk_home, directory, ports) if use_java
                   else docker_cluster(ports, directory.name))
        with cluster as stop_peer:
            wait_for_quorum(ports[:3])
            probe = subprocess.Popen(
                [str(probe_binary), HOST, *map(str, ports[:3]), name],
                stdout=sys.stdout, stderr=sys.stderr, creationflags=HIDDEN,
            )
            try:
                wait_for_signal(directory, "ready", probe)
                print("Stopping the first peer after authenticated watch registration", flush=True)
                stop_peer(0)
                wait_for_signal(directory, "restored", probe)
                print("Original session, identity, ephemeral node and watch recovered", flush=True)
                stop_peer(1)
                wait_for_signal(directory, "expired", probe)
                if probe.wait(timeout=10) != 0:
                    raise RuntimeError("recovery probe failed during cleanup")
                print("Session expired after quorum loss")
            finally:
                stop_process(probe)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(f"Cluster acceptance failed: {error}")
