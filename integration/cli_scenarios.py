"""Exercise the built MoonBit executables against an existing ZooKeeper server."""

import asyncio
import base64
from contextlib import asynccontextmanager
import os
from pathlib import Path
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "_build/native/debug/build"
DEADLINE = 15


def executable(package):
    basename = BUILD / package / Path(package).name
    for path in (basename.with_suffix(".exe"), basename):
        if path.is_file():
            return str(path)
    raise FileNotFoundError(f"Run 'moon build --target native' first. Missing {basename}")


@asynccontextmanager
async def start(command, *args, env):
    proc = await asyncio.create_subprocess_exec(
        command, *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, env=env,
    )
    try:
        yield proc
    finally:
        if proc.returncode is None:
            proc.kill()
        await proc.communicate()


async def line(stream):
    return (await asyncio.wait_for(stream.readline(), DEADLINE)).decode().rstrip("\r\n")


async def check_config_recovery(program, node, env, server_host, server_port, cli):
    """Send repeated healthy notifications, then drop TCP without changing the znode."""
    connections = set()

    async def copy(reader, writer):
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()

    async def forward(reader, writer):
        upstream_reader, upstream = await asyncio.open_connection(server_host, server_port)
        connections.add(writer)
        tasks = [asyncio.create_task(copy(reader, upstream)),
                 asyncio.create_task(copy(upstream_reader, writer))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            connections.discard(writer)
            upstream.close()
            writer.close()

    async with await asyncio.start_server(forward, "127.0.0.1", 0) as relay:
        proxy_port = str(relay.sockets[0].getsockname()[1])
        scoped_env = {**env, "MOONKEEPER_ZK_HOST": "127.0.0.1", "MOONKEEPER_ZK_PORT": proxy_port}
        updates = 12
        version = 2
        async with start(program, node, str(updates + 2), env=scoped_env) as watcher:
            assert await line(watcher.stdout) == f"version={version} data=b25l"
            for _ in range(updates):
                await cli("set", node, "--text", "one", "--version", str(version))
                version += 1
                assert await line(watcher.stdout) == f"version={version} data=b25l"
            assert len(connections) == 1
            next(iter(connections)).close()
            assert "stale" in await line(watcher.stderr)
            assert await line(watcher.stdout) == f"version={version} data=b25l"
            assert await asyncio.wait_for(watcher.wait(), DEADLINE) == 0
        return version


async def main():
    env = os.environ.copy()
    env.pop("MOONKEEPER_DIGEST", None)
    host = env.get("MOONKEEPER_ZK_HOST", "127.0.0.1")
    port = env.get("MOONKEEPER_ZK_PORT", "2181")
    server = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    keeper = executable("cmd/keeper")
    config_watch = executable("examples/config_watch")
    service = executable("examples/service_registration")

    async def cli(*args, exit_code=0, environment=env):
        async with start(keeper, "--servers", server, *args, env=environment) as proc:
            out, err = await asyncio.wait_for(proc.communicate(), DEADLINE)
            if proc.returncode != exit_code:
                raise AssertionError(f"{args[0]} exited {proc.returncode}, expected {exit_code}: {err!r}")
            if exit_code:
                assert err.strip() and not out, "failures must diagnose on stderr"
            return out.decode().rstrip("\r\n"), err.decode()

    path = "/moonkeeper-cli-" + uuid.uuid4().hex
    node = path + "/config"
    await cli("create", path)
    try:
        with tempfile.TemporaryDirectory(prefix="moonkeeper-cli-") as tmp:
            source, dest, auth = [Path(tmp) / name for name in ("in.bin", "out.bin", "credential")]
            payload = bytes(range(256)) + b"\x00\xff\n"
            source.write_bytes(payload)
            await cli("get", exit_code=2)
            await cli("unknown", node, exit_code=2)
            await cli("create", node, "--mode", "wrong", exit_code=2)
            await cli("delete", node, "--version", "-2", exit_code=2)
            await cli("create", node, "--file", str(dest), exit_code=2)
            secret = "fixture-must-stay-redacted"
            _, err = await cli("exists", path, environment={**env, "MOONKEEPER_DIGEST": secret}, exit_code=2)
            assert secret not in err
            auth.write_bytes(b"demo:throwaway-test-identity\r\n")
            assert (await cli("exists", path, "--auth-file", str(auth),
                              environment={**env, "MOONKEEPER_DIGEST": secret}))[0] == "true"
            assert (await cli("get", path))[0] == "(null)"
            assert (await cli("create", node, "--file", str(source)))[0] == node
            assert (await cli("get", node))[0] == base64.b64encode(payload).decode()
            dest.write_bytes(b"old" * 1000)
            await cli("get", node, "--output", str(dest))
            assert dest.read_bytes() == payload
            assert "version=0" in (await cli("stat", node))[0].splitlines()
            await cli("set", node, "--version", "8", "--text", "stale", exit_code=1)
            assert (await cli("children", path))[0] == "config"
            assert (await cli("set", node, "--version", "0", "--null"))[0] == "version=1"
            await cli("get", node, "--output", str(dest), exit_code=1)
            assert dest.read_bytes() == payload
            print("CLI exit codes, Digest source precedence, binary bytes and versions passed.")

        async with start(keeper, "--servers", server, "watch", node, "--kind", "data", env=env) as watcher:
            assert await line(watcher.stderr) == "watch armed"
            await cli("set", node, "--text", "one")
            assert await line(watcher.stdout) == f"NodeDataChanged {node}"
            assert await asyncio.wait_for(watcher.wait(), DEADLINE) == 0

        version = await check_config_recovery(config_watch, node, env, host, int(port), cli)
        print("Configuration watch marked its snapshot stale and reread it after reconnect.")

        async with start(config_watch, node, "3", env=env) as watcher:
            assert await line(watcher.stdout) == f"version={version} data=b25l"
            await cli("set", node, "--version", str(version), "--text", "two")
            assert await line(watcher.stdout) == f"version={version + 1} data=dHdv"
            await cli("delete", node, "--version", str(version + 1))
            assert await line(watcher.stdout) == "missing"
            assert await asyncio.wait_for(watcher.wait(), DEADLINE) == 0
            print("Configuration watch saw both updates and deletion across processes.")

        async with start(service, path, "localhost:8080", env=env) as registration:
            announced = await line(registration.stdout)
            assert announced.startswith(f"registered {path}/instance-"), announced
            instance = announced.removeprefix("registered ")
            assert (await cli("children", path))[0] == instance.rsplit("/", 1)[1]
            assert (await cli("get", instance))[0] == base64.b64encode(b"localhost:8080").decode()
            registration.stdin.write(b"\n")
            await registration.stdin.drain()
            assert await asyncio.wait_for(registration.wait(), DEADLINE) == 0
            await await_absence(cli, instance)
            print("Service appeared during its owner's session and disappeared on close.")
    finally:
        # This run exclusively owns the UUID root. Never traverse outside it.
        children, _ = await cli("children", path)
        for name in children.splitlines():
            if name.startswith("instance-"):
                await await_absence(cli, f"{path}/{name}")
            else:
                await cli("delete", f"{path}/{name}")
        await cli("delete", path)


async def await_absence(cli, path):
    async def poll():
        while (await cli("exists", path))[0] != "false":
            await asyncio.sleep(0.1)
    await asyncio.wait_for(poll(), 40)


if __name__ == "__main__":
    asyncio.run(main())
