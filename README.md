# OpenHands + vLLM LLM 部署紀錄

> 這份文件是「換機器重新架設 OpenHands / Agent Canvas + vLLM」時用的完整還原清單。
> 涵蓋：LLM profile、vLLM 模型、各 port 對應、GPU 配置、HTTPS relay、OpenHands 設定。
> 收集時間：2026-09-28 · 主機環境：Linux x86_64 · vLLM 0.28.0 · CUDA 13.0 · 7× NVIDIA B200

---

## 1. 硬體 / 環境

| 項目 | 值 |
|---|---|
| GPU | 7× NVIDIA B200（各 ~180 GB VRAM；NVIDIA-SMI 570.153.02 / CUDA 12.8 / CUDA 13.0 toolchain） |
| vLLM | `/mnt/venv/bin/vllm` v0.28.0（python venv） |
| HF 模型目錄 | `HF_HOME=/mnt/hf-cache` |
| vLLM 監聽 | `--host 0.0.0.0`（對外部可見） |
| Agent Canvas | `node /usr/bin/agent-canvas --port 3000`（ingress） |
| OpenHands SDK | `openhands-agent-server` / `sdk` / `tools` / `workspace` = **1.44.0** |
| HTTPS relay | `openhands-https.service`（node TLS byte relay，:3443 → 127.0.0.1:3000） |

### 主要 Port 總表

| Port | 服務 | 說明 |
|---|---|---|
| **8000** | ~~vLLM #1 → `deepseek-v4-flash`~~ | ~~DeepSeek-V4-Flash-0731~~（已停用，由 V4.1-Flash 取代） |
| **8011** | vLLM #4 → `deepseek-v41-flash` | DeepSeek-V4.1-Flash（Docker nightly，TP=4，GPU 0-3，256K ctx，kv-cache fp8） |
| **8001** | vLLM #2 → `qwen3.8-27b` | Qwen3.8-27B（TP=2，GPU 4-5，256K ctx，tool-call） |
| **8002** | vLLM #3 → `qwen3-vl` | Qwen3-VL-30B-A3B-Instruct（GPU 6，64K ctx，vision） |
| 18000 | OpenHands Agent Server | `agent-server --host 127.0.0.1 --port 18000` |
| 18001 | OpenHands Automations | `/api/automation/*` |
| 3000 | Agent Canvas ingress | 統一入口（route→18000/18001/3001） |
| 3001 | Frontend 靜態伺服器 | `static-server.mjs --dir .../build --port 3001` |
| **3443** | **HTTPS relay** | `openhands-https.service`：`https://<LAN-IP>:3443` → 3000 |
| 8090 | 其他 node 服務 | （附帶） |
| 80/443 | nginx 反向代理（BMC） | 127.0.0.1，勿動 |
| 8080 | open-webui | python |
| 6379 | redis | 127.0.0.1 |
| 22 | sshd | 遠端 |

> 架構要點：**每支模型用一個獨立 vLLM serve process**，各綁 8000~8002 port；
> 3 支 vLLM 共用同一份 `/mnt/hf-cache`。OpenAI 相容 API：`/v1`。

---

## 2. vLLM 模型（3 支）

| 模型 | 參數 | 量化/特性 | 上下文 | 能力 |
|---|---|---|---|---|
| `DeepSeek-V4-Flash-0731` | 284.3B | kv-cache fp8 | 262144 | ~~已停用~~（由 V4.1-Flash 取代） |
| `DeepSeek-V4.1-Flash` | 284.3B | kv-cache fp8 | 262144 | completion, tools（deepseek_v41 parser，Docker nightly） |
| `Qwen3.8-27B` | 27.3B | — | 262144 | completion, tools（qwen3_coder parser） |
| `Qwen3-VL-30B-A3B-Instruct` | 30.5B (MoE) | 含視覺 | 65536 | vision, completion |

### 各 Port 實際配置（systemd unit 內容）

| Service | 模型路徑 | port | TP | GPU | 特色 flag |
|---|---|---|---|---|---|
| `deepseek-v4-0731.service` | `/mnt/hf-cache/deepseek-ai/DeepSeek-V4-Flash-0731` | ~~8000~~ | ~~4~~ | ~~0-3~~ | **已停用**（由 V4.1-Flash Docker 取代） |
| `deepseek-v41-docker.service` | `/mnt/hf-cache/deepseek-ai/DeepSeek-V4.1-Flash` | 8011 | 4 | 0-3 | Docker `vllm/vllm-openai:cu134-nightly`，`--ipc=host --kv-cache-dtype fp8 --tool-call-parser deepseek_v41 --enforce-eager --default-chat-template-kwargs {"thinking":false}` |
| `qwen3-27b.service` | `/mnt/hf-cache/Qwen/Qwen3.8-27B` | 8001 | 2 | 4,5 | `--enable-auto-tool-choice --tool-call-parser qwen3_coder` |
| `qwen3-vl.service` | `/mnt/hf-cache/Qwen/Qwen3-VL-30B-A3B-Instruct` | 8002 | 1 | 6 | `--limit-mm-per-prompt {"image":1}`，`VLLM_ATTENTION_BACKEND=FLASH_ATTN` |

---

## 3. OpenHands LLM Profiles

> 位置：`~/.openhands/profiles/*.json`（每個一個 LLM）
> `api_key` 是 **Fernet 加密字串**（`gAAAAAB...`），不是明文；要解開需同機的 OpenHands 主 key，
> 所以換機時建議直接在 Agent Canvas UI 重新設定 key 即可，本 repo 內為佔位碼。

### Profile 對照表

| Profile 名稱 | model (litellm) | base_url | 對應 vLLM port | 特色設定 |
|---|---|---|---|---|
| `deepseek-v4-flash` | `openai/deepseek-v4-flash` | ~~`http://127.0.0.1:8000/v1`~~ | ~~8000~~ | **已停用** |
| `deepseek-v41-flash` | `openai/deepseek-v41-flash` | `http://127.0.0.1:8011/v1` | 8011 | `disable_vision=true`，`reasoning_effort=none`，`litellm_extra_body.chat_template_kwargs.thinking=false`，`extended_thinking_budget=200000` |
| `qwen3.8-27b` | `openai/qwen3.8-27b` | `http://127.0.0.1:8001/v1` | 8001 | `max_input_tokens=262144`，`reasoning_effort=none`，`enable_thinking=false` |
| `qwen3-vl-32b` | `openai/qwen3-vl` | `http://127.0.0.1:8002/v1` | 8002 | `capability_overrides.supports_vision=true`，`reasoning_effort=none` |

> ⚠️ **每個 profile 都必須設 `"reasoning_effort": "none"`**，見 §10。這是 2026-09-29 才發現的關鍵設定。

### 現行設定（`~/.openhands/settings.json`）
- `active_profile`: **`qwen3.8-27b`**
- `active_agent_profile_id`: `41fc4be1-fd05-4ca6-ae2e-8304fa9698a3`（default agent）
- agent: `CodeActAgent`（agent_kind=openhands，schema_version 5）
- 主要 llm（settings 內嵌）: `openai/qwen3.8-27b` @ `http://127.0.0.1:8001/v1`
- condenser: enabled, `max_size=240`, kind=`llm_summarizing`, keep_first=2
- title_llm_profile: `qwen3-vl-32b`
- 啟用技能：add-skill / agent-canvas-environment / agent-memory / agent-sdk-builder /
  canvas-extension-api / code-review / docker / github / openhands-api /
  openhands-automation / openhands-sdk / skill-creator

---

## 4. HTTPS relay（:3443 → :3000）

> 讓使用者可以用 `https://<LAN-IP>:3443` 連 Agent Canvas。這是 **node TLS byte relay**
> （`/opt/openhands-https/https-proxy.js`），不是 nginx。

- **為什麼要這層**：Agent Canvas 前端讀 workspace 檔走 `/api/conversations/{id}/workspace/{file}`，
  認證用 `X-Session-API-Key` header **或** `oh_workspace_session_key` cookie
  （`POST /api/auth/workspace-session` 配對）。
- **關鍵細節**：這顆 cookie 是 `SameSite=None; HttpOnly`，**必須要有 `Secure`**，否則瀏覽器
  （RFC：`SameSite=None` 必須 `Secure`）直接丟棄 → 讀檔 401。
- **relay 必須注入 `X-Forwarded-Proto: https`**（`https-proxy.js` 已內建），後端才會判定
  這是 https、cookie 才會附 `Secure`。若直接用純 byte relay 不注入，就會出現「http 能顯示、
  https 讀檔 401」的怪現象。
- relay 只改**第一個 HTTP header 塊**（注入 X-Forwarded-Proto），其餘位元原封不動 →
  WebSocket（/sockets）與 SSE 不受影響。**注意不能同時保留 `client.pipe(backend)`**，
  否則同一段資料會寫兩次、把 WebSocket 握手踩壞（會「已斷開連接」）。

### 部署

```bash
# 產生自簽憑證（把要訪問的 LAN IP 寫進 SAN）+ 裝 proxy + 裝 service + start
./https/gen-cert.sh 10.35.229.17 10.33.33.95
./https/deploy-https.sh 10.35.229.17      # 或 restore-on-new-machine.sh 3
```

瀏覽器首次會跳自簽憑證警告，按「繼續前往 / 不安全」即可。

---

## 5. 關鍵環境變數（還原用）

```bash
export HF_HOME=/mnt/hf-cache
export CUDA_HOME=/usr/local/cuda-13.0
export PATH=/usr/local/cuda-13.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64
export NCCL_SOCKET_IFNAME==lo
export NCCL_IB_DISABLE=1
export NCCL_NVLS_ENABLE=0
# OpenHands / Agent Canvas
# AGENT_SERVER_URL=http://127.0.0.1:18000
# 各 agent-server frontend 需 --session-api-key（啟動時由 runtime 注入，見 OH_SESSION_API_KEYS_0）
```

---

## 6. 換機還原步驟（摘要）

> **一鍵還原**：本 repo 提供 `restore-on-new-machine.sh`，新機直接跑
> `./restore-on-new-machine.sh --all` 即可依序重建（需先能進 GPU 環境）。
> 也可分步執行：`./restore-on-new-machine.sh 1|2|3|4|5|6`。
> HTTPS LAN IP 用 `--ips 10.35.229.17 10.33.33.95` 帶入（step3 產生自簽憑證 SAN）。

> **新機最快路徑**（假設 GPU driver/CUDA 已裝好、只要整套起來）：
> ```bash
> git clone https://github.com/wistroneq3300/openhands-llm-setup.git
> cd openhands-llm-setup
> ./restore-on-new-machine.sh --all --ips 10.35.229.17   # 1→2→3→4→5→6 一次跑完
> # 抓 HF 模型、部署 3× vLLM systemd、還原 profiles/settings、裝 SDK、起 Agent Canvas + HTTPS
> ```

1. **裝 GPU driver + CUDA 13.0 + venv + vLLM 0.28.0**（7× B200）。
2. **抓模型** `HF_HOME`（`/mnt/hf-cache`）：
   - `deepseek-ai/DeepSeek-V4-Flash-0731` / `Qwen/Qwen3.8-27B` / `Qwen/Qwen3-VL-30B-A3B-Instruct`
   - 或直接搬舊機整個 `/mnt/hf-cache`。
3. **部署並啟動 3 支 vLLM systemd**（8000~8002 port / CUDA_VISIBLE_DEVICES / TP / ctx，見 `systemd/`）+ HTTPS relay：
   ```bash
   ./restore-on-new-machine.sh 3        # 一步部署 + 啟動（含 HTTPS）
   ```
4. **裝 OpenHands SDK 1.44.0**（`openhands-agent-server` / `sdk` / `tools` / `workspace`，
   或 `./restore-on-new-machine.sh 5`）。
5. **起 Agent Canvas**：
   ```bash
   node /usr/bin/agent-canvas --port 3000   # ingress
   # 內部會帶起 agent-server(18000) / frontend(3001) / automation(18001)
   # HTTPS relay（:3443）由 step3 的 openhands-https.service 提供
   ```
6. **在 UI 重建 3 支 LLM profile**（名稱 / base_url / model / 參照本文第 3 節），
   重設 `api_key` 即可（Fernet key 是機器綁定，不必搬）。
7. 驗證：
   ```bash
   for p in 8000 8001 8002; do
     echo "== $p =="; curl -s localhost:$p/v1/models | head -c 200; echo
   done
   curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:3443/
   ```

---

## 7. 原始設定檔（供一一還原）

- `profiles/*.json` — 3 支 LLM profile 的**原始 JSON**（`api_key` 為佔位碼）。
- `settings.json` — 完整 `~/.openhands/settings.json` 快照。
- `systemd/` — 3 支 vLLM 的 systemd unit + HTTPS relay unit（`openhands-https.service`）。
- `https/` — HTTPS relay 源碼與部署：
  - `https-proxy.js`：node TLS byte relay（注入 `X-Forwarded-Proto: https`）
  - `gen-cert.sh`：產生自簽憑證（SAN 含 LAN IP）
  - `deploy-https.sh`：部署 relay + service 並啟動

> 新機裝好 SDK 後，直接把这些 JSON 放回對應目錄即可：
> - `profiles/*.json`  → `~/.openhands/profiles/`
> - `settings.json` → `~/.openhands/settings.json`
> - `systemd/*` → `/etc/systemd/system/`（`restore-on-new-machine.sh 3` 會自動做）
> ⚠️  `api_key` 是機器綁定的 Fernet 加密值，換機後建議在 UI 重設。

---

## 8. 附帶 Scripts

| Script | 用途 |
|---|---|
| `restore-on-new-machine.sh` | 新機一鍵還原:抓模型 → 部署 3× vLLM systemd → HTTPS relay → 還原 profiles/settings → 裝 SDK → 起 Agent Canvas。 |
| `https/gen-cert.sh` | 產生自簽 TLS 憑證（把 LAN IP 寫進 SAN）。 |
| `https/deploy-https.sh` | 部署 HTTPS relay（proxy + certs + systemd）。 |
| `diagnostics/check-reasoning-effort.py` | 檢查 `settings.json` 與每個 profile 的 `reasoning_effort` 是否為 `none`（見 §10）。 |
| `diagnostics/fix-existing-conversations.py` | 用 `switch_llm` 把**既有對話**的 `reasoning_effort` 改成 `none`（見 §10）。 |

- `./restore-on-new-machine.sh --all --ips <LAN-IP>`
- `./restore-on-new-machine.sh 3`
- `./https/gen-cert.sh <LAN-IP>`
- `./https/deploy-https.sh <LAN-IP>`
- `python3 diagnostics/check-reasoning-effort.py`
- `python3 diagnostics/fix-existing-conversations.py --all --dry-run`

---

## 9. 注意事項

- `DeepSeek-V4-Flash-0731` 為客製 fork（`frob/deepseek-v4-flash-0731`），**已停用**（2026-09-28），由 `DeepSeek-V4.1-Flash`（Docker nightly）取代。
- `DeepSeek-V4.1-Flash` 用 Docker（`vllm/vllm-openai:cu134-nightly`）啟動，systemd unit 為 `deepseek-v41-docker.service`（Type=oneshot + RemainAfterExit=yes + `--restart unless-stopped`）。**必須加 `--ipc=host`**（/dev/shm 預設 64MB 不夠 vLLM 用）。
- V4.1-Flash 的 weights 必須用官方 revision `dba1be0a` 下載；2026-09-28 發現 43/48 shards SHA256 不一致（內容損壞）→ 全部 inference NaN。修法：移除壞 shards → 重下 → `hf cache verify` 確認 48/48 通過。
- 每支 vLLM 的參數（TP/ctx/kv-cache/mmproj）依模型而異，搬模型時連 unit 一起記（見上表）。
- `api_key` 為機器綁定的加密值，換機後在 UI 重設即可，**不要把明文 key 放到 git**。
- HTTPS relay 一定要注入 `X-Forwarded-Proto: https` + 避免雙寫（會壞 WebSocket），
  見本文 §4（2026-09-28 實戰踩雷紀錄）。
- 本機 nginx 80/443 被 BMC proxy 佔用（`/etc/nginx/conf.d/bmc_proxy.conf`），HTTPS 走 3443 的 node relay，勿動 nginx。

---

## 10. ★ 推理洩漏（UI 出現一堆自言自語）的真正原因 — 2026-09-29

### 症狀
用 `deepseek-v41-flash` 對話時，模型整段**英文推理**會變成正式訊息顯示（不是可收合的 Thinking 區塊）。
把它當成「thinking 沒關掉」去改 `chat_template_kwargs.thinking=false` 是**沒用的**。

### 根因鏈（三層，缺一不可）
1. **OpenHands SDK 的 `LLM.reasoning_effort` 預設值是 `"high"`**
   `openhands/sdk/llm/llm.py` → `reasoning_effort: (...) = Field(default="high", ...)`
   profile 若**沒有這個 key**，就會 fallback 成 `"high"`；
   `openhands/sdk/llm/options/chat_options.py` 會把非 None 的值塞進請求 → **每次請求都送 `reasoning_effort="high"`**。

2. **vLLM 的 DeepSeek-V4 chat template 用 `reasoning_effort` 決定要不要開思考，會蓋掉 `thinking:false`。**
   實測（port 8011，真實 31K system prompt）：

   | `chat_template_kwargs` | `reasoning_effort` | 結果 |
   |---|---|---|
   | `{"thinking":false}` | （未送） | ✅ 乾淨 |
   | `{"thinking":false}` | `high` | ❌ **漏** |
   | `{"thinking":false}` | `low` | ❌ **漏** |
   | `{"thinking":false}` | `none` | ✅ 乾淨 |

3. **為什麼 UI 拆不掉**：開思考後，開頭的 ` thinking` 已被模板 prefill 吃掉，`content` 只剩
   `推理…</think>答案`。OpenHands 前端 `event-thought-helpers.js` 的 `splitInlineThink`
   **只認「content 以開頭標籤開頭」才會拆** → 拆不掉 → 整段推理當**正式訊息**顯示。

### 修法（vLLM 完全不用動、不用重啟）
`settings.json` 的 `agent_settings.llm.reasoning_effort`，以及**每個** `profiles/*.json`，都設：

```json
"reasoning_effort": "none"
```

> ⚠️ **必須是 `"none"`，不能是 `null`**。`null` 會被 SDK 的 default `"high"` 取代（實測驗證過）。
> ⚠️ `qwen3.8-27b` 對此**免疫**（它用 `enable_thinking`，SDK 只對支援 reasoning_effort 的模型塞該參數），
>    但為了統一還是全部設 `none`。

### 既有對話不會自動生效（設定在建立對話時就凍結）
- `PATCH /api/conversations/{id}` **只能改 title/tags**，改不了 LLM。
- 要用 `POST /api/conversations/{id}/switch_llm`，body 傳**完整 LLM 物件**：
  ```python
  prof = json.load(open('~/.openhands/profiles/deepseek-v41-flash.json'))
  LLM  = {k: v for k, v in prof.items()
          if k not in ('id', 'name', 'schema_version', 'display_name', 'description')}
  LLM['reasoning_effort'] = 'none'
  POST /api/conversations/{cid}/switch_llm   {"llm": LLM}
  ```
  header 用 `X-Session-API-Key`（key 在 `~/.openhands/agent-canvas/api-key.txt`）。
- 正在跑（running）的對話可以改成功；**已結束（finished）的對話改了不會生效** → 開新對話最快。

### 驗證方式
```bash
python3 diagnostics/check-reasoning-effort.py
```

### 走過的死路（別重犯）
- ❌ 以為是 `think` tool → 改 `node_modules/.../prompts/system-prompt.js` 的 think 說明，**無效**（已還原）。
- ❌ 以為是 profile 的 `thinking:false` 壞了 → 其實它好的，是被 `reasoning_effort` 蓋掉。
- ❌ 設 `reasoning_effort = null` → **無效**（會被 default `high` 取代）。

