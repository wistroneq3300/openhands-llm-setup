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
| **8000** | vLLM #1 → `deepseek-v4-flash` | DeepSeek-V4-Flash-0731（TP=4，GPU 0-3，256K ctx，kv-cache fp8） |
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
| `DeepSeek-V4-Flash-0731` | 284.3B | kv-cache fp8 | 262144 | completion, tools（deepseek_v4 parser） |
| `Qwen3.8-27B` | 27.3B | — | 262144 | completion, tools（qwen3_coder parser） |
| `Qwen3-VL-30B-A3B-Instruct` | 30.5B (MoE) | 含視覺 | 65536 | vision, completion |

### 各 Port 實際配置（systemd unit 內容）

| Service | 模型路徑 | port | TP | GPU | 特色 flag |
|---|---|---|---|---|---|
| `deepseek-v4-0731.service` | `/mnt/hf-cache/deepseek-ai/DeepSeek-V4-Flash-0731` | 8000 | 4 | 0-3 | `--kv-cache-dtype fp8 --tool-call-parser deepseek_v4 --default-chat-template-kwargs {"thinking":false}` |
| `qwen3-27b.service` | `/mnt/hf-cache/Qwen/Qwen3.8-27B` | 8001 | 2 | 4,5 | `--enable-auto-tool-choice --tool-call-parser qwen3_coder`，⚠️ 需 `NCCL_NVLS_ENABLE=0` + `VLLM_ALLREDUCE_USE_SYMM_MEM=0` + `--disable-custom-all-reduce`（見 §9） |
| `qwen3-vl.service` | `/mnt/hf-cache/Qwen/Qwen3-VL-30B-A3B-Instruct` | 8002 | 1 | 6 | `--limit-mm-per-prompt {"image":1}`，`VLLM_ATTENTION_BACKEND=FLASH_ATTN` |

### 效能優化（2026-09-28）— 三支全改 `--enforce-eager` 移除

> 重點：`--enforce-eager` 會強制 vLLM 關閉 **CUDA graph / torch.compile**，
> 在 B200 上對 decode 傷害極大。三支 service 都移除該 flag 後獲得大幅加速，
> **context 完全不動**（deepseek/qwen 維持 262144、qwen3-vl 維持 65536）。

| Service | 移除前 tok/s | 移除後 tok/s | 加速 | 2048-token 生成時間 |
|---|---|---|---|---|
| `deepseek-v4-0731`（TP4） | 16 | **141** | **~8.5x** | 117s → 6~15s |
| `qwen3-27b`（TP2） | 35 | **116** | **3.3x** | 58s → 17.6s |
| `qwen3-vl`（TP1 / MoE A3B） | ~35 | **294** | **~8.4x** | ~58s → 7s |

- 完整 A/B 測試數據見 [`bench/REPORT.md`](bench/REPORT.md)（同套題 5 題 ×2 runs，GPU 空閒）。
- 三支 service 的現行內容都已更新（`systemd/*.service`），換機還原直接使用即可。
- 備份：改動前的 service 檔保留為 `*.bak-preBC-*` / `*.bak-preD1-*` / `*.bak-preB-*`（未進 repo）。

---

## 3. OpenHands LLM Profiles

> 位置：`~/.openhands/profiles/*.json`（每個一個 LLM）
> `api_key` 是 **Fernet 加密字串**（`gAAAAAB...`），不是明文；要解開需同機的 OpenHands 主 key，
> 所以換機時建議直接在 Agent Canvas UI 重新設定 key 即可，本 repo 內為佔位碼。

### Profile 對照表

| Profile 名稱 | model (litellm) | base_url | 對應 vLLM port | 特色設定 |
|---|---|---|---|---|
| `deepseek-v4-flash` | `openai/deepseek-v4-flash` | `http://127.0.0.1:8000/v1` | 8000 | `disable_vision=true`，`litellm_extra_body.chat_template_kwargs.thinking=false` |
| `qwen3.8-27b` | `openai/qwen3.8-27b` | `http://127.0.0.1:8001/v1` | 8001 | `max_input_tokens=262144`，`enable_thinking=false` |
| `qwen3-vl-32b` | `openai/qwen3-vl` | `http://127.0.0.1:8002/v1` | 8002 | `capability_overrides.supports_vision=true` |

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

- `./restore-on-new-machine.sh --all --ips <LAN-IP>`
- `./restore-on-new-machine.sh 3`
- `./https/gen-cert.sh <LAN-IP>`
- `./https/deploy-https.sh <LAN-IP>`

---

## 9. 注意事項

- `DeepSeek-V4-Flash-0731` 為客製 fork（`frob/deepseek-v4-flash-0731`），官方 registry 可能沒有，
  務必隨 `/mnt/hf-cache` 一起搬。
- 每支 vLLM 的參數（TP/ctx/kv-cache/mmproj）依模型而異，搬模型時連 unit 一起記（見上表）。
- `api_key` 為機器綁定的加密值，換機後在 UI 重設即可，**不要把明文 key 放到 git**。
- HTTPS relay 一定要注入 `X-Forwarded-Proto: https` + 避免雙寫（會壞 WebSocket），
  見本文 §4（2026-09-28 實戰踩雷紀錄）。
- 本機 nginx 80/443 被 BMC proxy 佔用（`/etc/nginx/conf.d/bmc_proxy.conf`），HTTPS 走 3443 的 node relay，勿動 nginx。
- ⚠️ **NVLink SHARP (NVLS) fabric 踩雷（2026-09-28）**：有人在有 LLM 服務運行時 `systemctl restart nvidia-fabricmanager`，它會連帶重啟 NVLink Subnet Manager(OpenSM)、把 NVLink SHARP 多播 fabric 拆掉重建；若同時有 vLLM 正要 join NVLS 群組，driver 快取狀態會卡在 `NV_ERR_FABRIC_STATE_OUT_OF_SYNC`，之後該服務每次啟動都報 `NCCL error: unhandled cuda error` 無限重啟，直到 reboot。**因此 `qwen3-27b.service` 用 `NCCL_NVLS_ENABLE=0` + `VLLM_ALLREDUCE_USE_SYMM_MEM=0` + `--disable-custom-all-reduce` 繞過 NVLS**（跟 deepseek 一樣走純 NCCL P2P）。**不要隨便移除這三個參數**；只有 reboot 讓 fabric 重新初始化後才能還原。避免在有服務運行時動 `nvidia-fabricmanager`（要動就先停 vLLM 或直接 reboot）。
