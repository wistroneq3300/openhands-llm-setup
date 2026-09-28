import json, time, urllib.request, urllib.error

MODELS = [
    ("qwen3.8-27b", "http://127.0.0.1:8001/v1"),
    ("deepseek-v4-flash", "http://127.0.0.1:8000/v1"),
]

PROBLEMS = [
    ("P1-数论(短)", [{"role":"user","content":"请证明：对任意正整数 n，n^3 - n 必能被 6 整除。请写出完整严密的证明过程（考虑所有情形），并说明为何 2 与 3 的整除性必须分开处理。最后给出反例检查：若把结论改为「能被 12 整除」是否成立，举反例验证。"}]),
    ("P2-算法(短)", [{"role":"user","content":"设计算法：给定 N=10^5 个区间 [l_i, r_i]，找出最少需要移除多少个区间，使剩下的区间两两不重叠。要求：1) 说明贪心策略并证明其正确性；2) 给出完整 Python 实作；3) 分析时间空间复杂度；4) 处理边界情形（l==r、嵌套包含、空输入）。"}]),
    ("P3-动态规划(短)", [{"role":"user","content":"给定 n 个物品、背包容量 W=10^5，每个物品有重量 w_i 与价值 v_i（1<=w_i<=10^4, 1<=v_i<=10^9），求最大价值。要求：1) 分析 0/1 背包在此规模下的 DP 可行性；2) 给出 meet-in-the-middle 或分支定界思路；3) 实作一个对 W=10^5 可跑的解法；4) 说明何时此问题可近似、近似比多少。"}]),
    ("P4-系统设计(短)", [{"role":"user","content":"设计一个能处理 100 万 QPS 的分布式限流器。要求：1) 比较 Redis 令牌桶 / 滑动窗口 / 分布式协议（Raft）三种方案的延迟、正确性、可用性；2) 说明在跨数据中心部署时的时钟漂移问题如何处理；3) 给出核心数据结构与伪代码；4) 列出至少 5 个故障模式及其缓解方式。"}]),
]

FAKE_CODE = """import asyncio
from dataclasses import dataclass
from typing import Dict, List, Optional
import redis.asyncio as aioredis
import orjson

@dataclass
class Task:
    id: str
    fn: callable
    args: tuple
    retries: int = 3
    timeout: float = 30.0

class TaskQueue:
    def __init__(self, redis_url: str, max_workers: int = 10):
        self._redis = aioredis.from_url(redis_url, decode_responses=True)
        self._workers: List[asyncio.Task] = []
        self._pending: Dict[str, Task] = {}
        self._max_workers = max_workers
        self._shutdown = False

    async def start(self):
        for i in range(self._max_workers):
            self._workers.append(asyncio.create_task(self._worker(i)))

    async def _worker(self, wid: int):
        while not self._shutdown:
            try:
                item = await self._redis.blpop(f"queue:worker:{wid}", timeout=5)
                if not item:
                    continue
                task_id = orjson.loads(item[1])["id"]
                task = self._pending.pop(task_id, None)
                if task is None:
                    continue
                await self._run_with_retry(task)
            except Exception:
                await asyncio.sleep(1)

    async def _run_with_retry(self, task: Task):
        for attempt in range(task.retries):
            try:
                await asyncio.wait_for(task.fn(*task.args), timeout=task.timeout)
                return
            except asyncio.TimeoutError:
                continue
            except Exception:
                break
        await self._redis.set(f"failed:{task.id}", orjson.dumps({"retries": attempt}))

    async def enqueue(self, task: Task):
        self._pending[task.id] = task
        await self._redis.rpush(f"queue:worker:{task.id % self._max_workers}",
                                orjson.dumps({"id": task.id}))

    async def stop(self):
        self._shutdown = True
        for w in self._workers:
            w.cancel()
        await self._redis.aclose()
"""

LONG_HISTORY = [
    {"role":"system","content":"你是一个资深 Python 工程师，协助调试与重构项目。回答要精确、给出代码。"},
    {"role":"user","content":"这是一个任务队列的实现：\n" + FAKE_CODE + "\n请检查有没有 bug。"},
    {"role":"assistant","content":"我看到几个问题：1) `_worker` 用 blpop 但 key 是 `queue:worker:{wid}`，而 `enqueue` 推到 `queue:worker:{task.id % max_workers}`，两者一致所以没问题。2) `_run_with_retry` 的 failed 记录用了 `attempt` 变量，但 for 循环 break 时 attempt 可能是旧值。3) `stop()` 没有 drain 未完成任务。"},
    {"role":"user","content":"对，第 3 点很重要。请重构 stop() 让它能 drain 所有 pending 任务，并加一个 graceful_shutdown 的 timeout 参数。"},
    {"role":"assistant","content":"好的，我会重构 stop() 加入 drain 逻辑与 timeout。同时把 pending 从 dict 改成用 redis 做持久化，避免 crash 后遗失。"},
    {"role":"user","content":"不用持久化到 redis，用内存就好，但要保证 stop 时 log 出未完成任务清单。另外把 retry 的 backoff 改成指数退避。"},
]
LONG_SUFFIX = "现在请：1) 重构上面的代码，加入 graceful shutdown（drain + timeout + log 未完成任务）；2) retry 改为指数退避（base=1s, cap=30s）；3) 补充 unit test 覆盖 shutdown 与 retry 路径；4) 说明并发安全性的考量。"
PROBLEMS.append(("L1-长context", LONG_HISTORY + [{"role":"user","content":LONG_SUFFIX}]))

def call(base_url, model, messages, max_tokens=2048):
    body = {"model": model, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0.0, "stream": False}
    data = json.dumps(body).encode()
    req = urllib.request.Request(base_url + "/chat/completions", data=data,
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=900) as resp:
        payload = json.loads(resp.read())
    dt = time.perf_counter() - t0
    usage = payload.get("usage", {})
    content = payload["choices"][0]["message"]["content"]
    return {"prompt_tokens": usage.get("prompt_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
            "wall_s": dt, "content_len": len(content),
            "cached": (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)}

def main():
    results = []
    for model, base in MODELS:
        for name, msgs in PROBLEMS:
            for run in range(1, 3):
                try:
                    r = call(base, model, msgs)
                    r.update(model=model, problem=name, run=run)
                    it = r["completion_tokens"] / r["wall_s"] if r["wall_s"] > 0 else 0
                    results.append({**r, "tok_per_s": round(it, 1)})
                    print(f"[{model}] {name} run{run}: {r['wall_s']:.1f}s out={r['completion_tokens']} tok/s={it:.1f} in={r['prompt_tokens']} cached={r['cached']}", flush=True)
                except Exception as e:
                    print(f"[{model}] {name} run{run}: ERROR {e}", flush=True)
                    results.append({"model": model, "problem": name, "run": run, "error": str(e)})
    with open("results.json", "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print("DONE", flush=True)

if __name__ == "__main__":
    main()
