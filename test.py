import time
import asyncio
import httpx
from concurrent.futures import ProcessPoolExecutor


async def make_req(client):
    try:
        r = await client.post("/ping", data=b"Ping!")
        return r.text
    except Exception as e:
        return e

async def main(qtd = 100):
    reqs = []
    async with httpx.AsyncClient(base_url="http://localhost:8000", timeout=15) as client:
        for _ in range(qtd):
            reqs.append(make_req(client))
        res = await asyncio.gather(*reqs)
    return res

def run_main(qtd):
    loop = asyncio.new_event_loop()
    res = loop.run_until_complete(main(qtd))
    return res

if __name__ == "__main__":
    p, qtd = 200, 150
    v = [qtd for _ in range(p)]
    # 8 workers seems to work better
    with ProcessPoolExecutor(max_workers=8) as executor:
        t1 = time.time()
        res = executor.map(run_main, v)
    t2 = time.time()
    for r in res:
        re = len([v for v in r if isinstance(v, httpx.ReadError)])
        print((r[0], re))
    print(f"{(qtd*p) / (t2-t1)} req/s")
