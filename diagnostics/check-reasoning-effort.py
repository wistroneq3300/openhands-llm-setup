#!/usr/bin/env python3
"""check-reasoning-effort.py — 驗證 OpenHands 的 reasoning_effort 是否已關閉。

為什麼要檢查：OpenHands SDK 的 LLM.reasoning_effort 預設值是 "high"，
而 vLLM 的 DeepSeek-V4 chat template 會用 reasoning_effort 決定要不要開思考，
**蓋掉** chat_template_kwargs.thinking=false → 推理會漏進 content，
在 UI 變成一堆英文自言自語。必須在 settings.json 與每個 profile 設
"reasoning_effort": "none"（不能用 null，會被 default "high" 取代）。

用法：
    python3 diagnostics/check-reasoning-effort.py [--openhands-home ~/.openhands]

離開碼：0 = 全部正確，1 = 有問題
"""
import argparse
import glob
import json
import os
import sys

OK = "\033[1;32mOK\033[0m"
BAD = "\033[1;31mBAD\033[0m"


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--openhands-home",
                    default=os.path.expanduser("~/.openhands"),
                    help="OpenHands 設定目錄（預設 ~/.openhands）")
    args = ap.parse_args()
    home = args.openhands_home

    problems = []
    checked = 0

    settings = os.path.join(home, "settings.json")
    if os.path.isfile(settings):
        checked += 1
        d = load(settings)
        v = ((d.get("agent_settings") or {}).get("llm") or {}).get("reasoning_effort")
        if v == "none":
            print("[%s] settings.json  agent_settings.llm.reasoning_effort = 'none'" % OK)
        else:
            print("[%s] settings.json  agent_settings.llm.reasoning_effort = %r" % (BAD, v))
            if v is None:
                problems.append("settings.json: 欄位不存在或為 null → SDK 會 fallback 成 "
                                "'high' 並送出，請明確設成 \"none\"")
            else:
                problems.append("settings.json: %r 不是 'none'" % v)
    else:
        print("[!!] 找不到 %s" % settings)
        problems.append("找不到 settings.json")

    for p in sorted(glob.glob(os.path.join(home, "profiles", "*.json"))):
        name = os.path.basename(p)
        if ".bak" in name:
            continue
        checked += 1
        d = load(p)
        v = d.get("reasoning_effort")
        extra = (d.get("litellm_extra_body") or {}).get("chat_template_kwargs") or {}
        if v == "none":
            print("[%s] profiles/%-28s reasoning_effort = 'none'   (chat_template_kwargs=%s)"
                  % (OK, name, json.dumps(extra, ensure_ascii=False)))
        else:
            print("[%s] profiles/%-28s reasoning_effort = %r" % (BAD, name, v))
            problems.append("profiles/%s: 請加 \"reasoning_effort\": \"none\"（不是 null）" % name)

    print()
    if checked == 0:
        print("沒有檢查到任何設定檔（home=%s）" % home)
        return 1
    if problems:
        print("發現 %d 個問題：" % len(problems))
        for x in problems:
            print("  - " + x)
        print()
        print("提醒：只有 'none' 有效。null / 缺欄位 → SDK default 'high' → "
              "DeepSeek-V4 模板會開思考 → UI 出現一堆自言自語。")
        return 1
    print("全部正確：reasoning_effort = 'none' ✅")
    print("（既有對話的設定在建立時就凍結，需用 "
          "POST /api/conversations/{id}/switch_llm 修正，或直接開新對話）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
