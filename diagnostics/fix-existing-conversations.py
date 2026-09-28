#!/usr/bin/env python3
"""fix-existing-conversations.py — 把既有對話的 reasoning_effort 改成 none。

背景：對話的 LLM 設定在「建立對話時」就凍結了，之後改 settings.json / profiles
不會影響既有對話。`PATCH /api/conversations/{id}` 只能改 title/tags，
所以要改用 `POST /api/conversations/{id}/switch_llm` 並傳完整 LLM 物件。

注意：
- 正在跑（running）的對話可以改成功。
- 已結束（finished）的對話改了通常不會生效 → 直接開新對話最快。

用法：
    python3 diagnostics/fix-existing-conversations.py --dry-run
    python3 diagnostics/fix-existing-conversations.py --all
    python3 diagnostics/fix-existing-conversations.py <conversation-id> [<id>...]
    python3 diagnostics/fix-existing-conversations.py --all --profile deepseek-v41-flash
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_BASE = "http://localhost:3000"
AGENT_CANVAS_DIR = os.path.expanduser("~/.openhands/agent-canvas")
PROFILES_DIR = os.path.expanduser("~/.openhands/profiles")

# switch_llm 只吃 LLM 本體，不吃 profile 的外層中介資料
_PROFILE_JUNK = ("id", "name", "schema_version", "display_name", "description",
                 "agent_kind", "llm_profile_ref")


def read_key(explicit=None):
    if explicit:
        return open(explicit, encoding="utf-8").read().strip()
    for cand in ("api-key.txt", "secret-key.txt"):
        p = os.path.join(AGENT_CANVAS_DIR, cand)
        if os.path.isfile(p):
            return open(p, encoding="utf-8").read().strip()
    sys.exit("找不到 API key（%s/api-key.txt），請用 --api-key-file 指定" % AGENT_CANVAS_DIR)


def api(base, key, path, method="GET", body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"X-Session-API-Key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print("    !! HTTP %s %s" % (e.code, e.read().decode()[:240]))
        return None


def build_llm(profile_name):
    p = os.path.join(PROFILES_DIR, profile_name + ".json")
    if not os.path.isfile(p):
        sys.exit("找不到 profile: %s" % p)
    with open(p, encoding="utf-8") as f:
        prof = json.load(f)
    llm = {k: v for k, v in prof.items() if k not in _PROFILE_JUNK}
    llm["reasoning_effort"] = "none"
    return llm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("conversation_ids", nargs="*")
    ap.add_argument("--all", action="store_true", help="處理所有對話（跳過已正確的）")
    ap.add_argument("--profile", default="deepseek-v41-flash",
                    help="要推送的 LLM profile（預設 deepseek-v41-flash）")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--api-key-file", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="連 model 不同的對話也硬改（預設會跳過，避免意外換模型）")
    args = ap.parse_args()

    key = read_key(args.api_key_file)
    llm = build_llm(args.profile)
    print("要推送的 LLM: model=%s base_url=%s reasoning_effort=%s"
          % (llm.get("model"), llm.get("base_url"), llm.get("reasoning_effort")))

    ids = list(args.conversation_ids)
    if args.all:
        res = api(args.base, key, "/api/conversations/search?limit=100") or {}
        for c in res.get("items") or res.get("conversations") or []:
            if isinstance(c, dict) and c.get("id"):
                ids.append(c["id"])
    if not ids:
        ap.error("請給 conversation id，或用 --all")

    print()
    changed = skipped = failed = 0
    for cid in ids:
        info = api(args.base, key, "/api/conversations/" + cid)
        if not info:
            failed += 1
            continue
        cur = (info.get("agent") or {}).get("llm") or {}
        before = cur.get("reasoning_effort")
        status = info.get("execution_status")
        print("%s  model=%s reasoning_effort=%r status=%s"
              % (cid, cur.get("model"), before, status))
        if before == "none":
            print("    -> 已經正確，跳過")
            skipped += 1
            continue
        if cur.get("model") != llm.get("model") and not args.force:
            print("    -> 跳過（此對話用 %s，不是 %s；要硬改請加 --force）"
                  % (cur.get("model"), llm.get("model")))
            skipped += 1
            continue
        if args.dry_run:
            print("    -> [dry-run] 會變成 'none'")
            continue
        r = api(args.base, key, "/api/conversations/%s/switch_llm" % cid,
                "POST", {"llm": llm})
        if r is None:
            failed += 1
            continue
        time.sleep(2)
        after = ((api(args.base, key, "/api/conversations/" + cid)
                  or {}).get("agent") or {}).get("llm") or {}
        v = after.get("reasoning_effort")
        if v == "none":
            print("    -> ✅ 已修正")
            changed += 1
        else:
            print("    -> ⚠️ 沒生效（仍為 %r）；已結束的對話常這樣，開新對話最快" % v)
            failed += 1

    print()
    print("結果：修正 %d / 跳過 %d / 失敗 %d" % (changed, skipped, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
