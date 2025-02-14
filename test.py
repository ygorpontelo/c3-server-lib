import time
import asyncio
import httpx
from concurrent.futures import ProcessPoolExecutor


async def make_req(client):
    try:
        r = await client.post("/ping", data=b"Ping!")
        return r.text
    except Exception:
        return "error read"


async def main(qtd = 100):
    reqs = []
    async with httpx.AsyncClient(base_url="http://localhost:8000", timeout=15) as client:
        for _ in range(qtd):
            reqs.append(make_req(client))
        # t1 = time.time()
        res = await asyncio.gather(*reqs)
        # t2 = time.time()
    return res
    # print(res)
    # print(res[0])
    # print(len(res))
    # print(t2-t1)
    # print(f"{qtd/(t2-t1)} req/s")

def run_main(qtd):
    loop = asyncio.new_event_loop()
    res = loop.run_until_complete(main(qtd))
    return res[0]

if __name__ == "__main__":
    p, qtd = 250, 200
    v = [qtd for _ in range(p)]
    with ProcessPoolExecutor(max_workers=16) as executor:
        t1 = time.time()
        r = executor.map(run_main, v)
    t2 = time.time()
    print(list(r))
    print(f"{(qtd*p) / (t2-t1)} req/s")
