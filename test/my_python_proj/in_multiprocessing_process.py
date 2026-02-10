import asyncio

import snex


async def do_something_async(
    pid: snex.Term,
    socket_path: str,
) -> int:
    reader, writer = await asyncio.open_unix_connection(socket_path)
    async with snex.serve(reader, writer):
        await snex.send(pid, "hello from the subprocess via socket")
        return await snex.call("Elixir.System", "pid", [])


def do_something(
    pid: snex.Term,
    socket_path: str,
) -> int:
    return asyncio.run(do_something_async(pid, socket_path))
