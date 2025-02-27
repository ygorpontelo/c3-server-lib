import time
import httpx
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor

def run_main(qtd):
    with httpx.Client(base_url="http://localhost:8000", timeout=15) as client:
        def req(data):
            return client.post("/ping", data=data).text
        with ThreadPoolExecutor(8) as executor:
            res = executor.map(req, ["Ping!" for _ in range(qtd)])
    return list(res)

if __name__ == "__main__":
    p, qtd = 512, 512
    v = [qtd for _ in range(p)]
    with ProcessPoolExecutor(max_workers=12) as executor:
        t1 = time.time()
        res = executor.map(run_main, v)
    t2 = time.time()
    for r in res:
        re = len([v for v in r if isinstance(v, httpx.ReadError)])
        if re > 0:
            print(f"error read: {re}")
    print(f"{(qtd*p) / (t2-t1)} req/s")
