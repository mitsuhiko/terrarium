# asyncio: doing many things at once while waiting.
#
# Asking a server for something is mostly waiting for the answer. With
# async and await, a program starts the next request while the first one
# is still on its way. Here we ask PyPI for the newest version of some
# packages: one after another, then all at once with asyncio.gather.
import asyncio
import time

import httpx

PACKAGES = ["requests", "numpy", "pandas", "flask", "django", "rich", "httpx", "pillow"]


async def latest(client, name):
    """The newest version of a package and its one-line summary."""
    response = await client.get(f"https://pypi.org/pypi/{name}/json")
    response.raise_for_status()
    info = response.json()["info"]
    return name, info["version"], info["summary"]


async def one_after_another(client):
    return [await latest(client, name) for name in PACKAGES]


async def all_at_once(client):
    return await asyncio.gather(*(latest(client, name) for name in PACKAGES))


async def as_they_arrive(client):
    """Print each answer the moment it arrives (not in the order asked)."""
    tasks = [asyncio.create_task(latest(client, name)) for name in PACKAGES]
    for finished in asyncio.as_completed(tasks):
        name, version, _ = await finished
        print(f"  {name} {version}")


async def main():
    async with httpx.AsyncClient(timeout=20) as client:
        start = time.perf_counter()
        await one_after_another(client)
        slow = time.perf_counter() - start
        print(f"One after another: {slow:.2f} s")

        start = time.perf_counter()
        results = await all_at_once(client)
        fast = time.perf_counter() - start
        print(f"All at once:       {fast:.2f} s ({slow / fast:.1f}x as fast)\n")

        for name, version, summary in results:
            print(f"{name} {version}: {summary}")

        print("\nAs they arrive:")
        await as_they_arrive(client)

        # A time limit: what isn't done after 10 milliseconds is cancelled.
        try:
            async with asyncio.timeout(0.01):
                await all_at_once(client)
            print("\nAll done within 10 ms!")
        except TimeoutError:
            print("\nNot done within 10 ms: cancelled.")


asyncio.run(main())
