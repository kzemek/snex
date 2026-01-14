import asyncio

import snex


async def do_something_async(pid: snex.Term) -> int:
    snex.send(pid, "hello from the subprocess")
    return await snex.call("Elixir.System", "pid", [])


def do_something(pid: snex.Term, remote_snex_connection: snex.RemoteConnection) -> int:
    with remote_snex_connection.remote_snex_thread():
        return asyncio.run(do_something_async(pid))
