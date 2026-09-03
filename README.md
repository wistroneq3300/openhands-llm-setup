# OpenHands + Ollama LLM 部署紀錄

> 這份文件是「換機器重新架設 OpenHands / Agent Canvas + Ollama」時用的完整還原清單。
> 涵蓋：LLM profile、Ollama 模型、各 port 對應、GPU 配置、OpenHands 設定。
> 收集時間：2026-09-03 · 主機環境：Linux x86_64 · Ollama 0.33.2 · CUDA 12.8

---

## 1. 硬體 / 環境

| 項目 | 值 |
|---|---|
| GPU | 3× NVIDIA B200（各 ~180 GB VRAM；NVIDIA-SMI 570.153.02 / CUDA 12.8） |
| Ollama | `/usr/local/bin/ollama` v0.33.2 |
| Ollama 模型目錄 | `OLLAMA_MODELS=/mnt/ollama_models` |
| Ollama 監聽 | `OLLAMA_HOST=0.0.0.0`（對外部可見） |
| Agent Canvas | `node /usr/bin/agent-canvas --port 3000`（OpenHands） |
| OpenHands SDK | `openhands-agent-server` / `sdk` / `tools` / `workspace` = **1.44.0** |

### 主要 Port 總表

| Port | 服務 | 說明 |
|---|---|---|
| **11434** | Ollama #1 → `deepseek-v4-last` | frob/deepseek-v4-flash-0731 (284.3B) |
| **11435** | Ollama #2 → `qwen3.8-27b` | qwen3.8:27b (27.3B) ctx 65536 |
| **11436** | Ollama #3 → `qwen3.8-sheng` | qwen3.8:27b (27.3B) ctx 131072 |
| **11437** | Ollama #4 → `qwen3-coder` | qwen3-coder:latest (30.5B) |
| **11438** | Ollama #5 → `qwen3-vl-32b` | qwen3-vl:32b (33.4B，含視覺) |
| 18000 | OpenHands Agent Server | `agent-server --host 127.0.0.1 --port 18000` |
| 18001 | OpenHands Automations | `/api/automation/*` |
| 3000 | Agent Canvas ingress | 統一入口（route→18000/18001/3001） |
| 3001 | Frontend 靜態伺服器 | `static-server.mjs --dir .../build --port 3001` |
| 8090 | 其他 node 服務 | （附帶） |
| 80/443 | nginx 反向代理 | 127.0.0.1 |
| 8080 | open-webui | python |
| 6379 | redis | 127.0.0.1 |
| 22 | sshd | 遠端 |

> 架構要點：**每個 Ollama 獨立跑一個 `ollama serve`**，各自綁一個 1143x port；
> 底下是各自 `llama-server`（GGUF）進程，吃同一組 GPU。5 個 Ollama 共享同一份
> `/mnt/ollama_models`，所以每個 port 的 `/api/tags` 都列出全部 4 支模型，
> **實際在跑的模型看 `/api/ps`**（下表）。

---

## 2. Ollama 模型（`/api/tags`）

每支 Ollama 都載入同一群模型（同一 `OLLAMA_MODELS`）：

| 模型 | 參數 | 量化 | 上下文 | 能力 |
|---|---|---|---|---|
| `qwen3-coder:latest` | 30.5B (MoE) | Q4_K_M | 262144 | completion, tools |
| `frob/deepseek-v4-flash-0731:latest` | 284.3B | MXFP4_MOE | — | completion |
| `qwen3.8:27b` | 27.3B | Q4_K_M | 262144 | completion, tools, thinking, vision |
| `qwen3-vl:32b` | 33.4B | Q4_K_M | 262144 | vision, completion, tools, thinking |

### 各 Port 實際載入（`/api/ps`）= 誰在跑誰

| Port | 實際 loaded 模型 | ctx (運行) |
|---|---|---|
| 11434 | `frob/deepseek-v4-flash-0731:latest` | 131072 |
| 11435 | `qwen3.8:27b` | 65536 |
| 11436 | `qwen3.8:27b` | 131072 |
| 11437 | `qwen3-coder:latest` | 32768 |
| 11438 | `qwen3-vl:32b` | 32768 |

### 跑起來的 `llama-server` 參數（`ps aux` 抓的，還原推理參數用）

| Port | 上下文 `-c` | 備註 |
|---|---|---|
| 11434 (deepseek 284B) | 1048576, `-np 8` | 大模型，吃滿 VRAM |
| 11435 (qwen3.8 27b) | 65536 | `--main-gpu 0`, `--mmproj`, `draft-mtp` speculate |
| 11436 (qwen3.8 27b) | 131072 | 同上不同 ctx |
| 11437 (qwen3-coder) | 32768, `-np 4` | |
| 11438 (qwen3-vl 32b) | 32768 | `--mmproj`（視覺投影） |

> 共同參數：`--flash-attn on -b 2048 -ub 2048 --context-shift --keep 4 --offline --no-webui --chat-template chatml`

---

## 3. OpenHands LLM Profiles

> 位置：`~/.openhands/profiles/*.json`（每個一個 LLM）
> `api_key` 是 **Fernet 加密字串**（`gAAAAAB...`），不是明文；要解開需同機的 OpenHands 主 key，
> 所以換機時建議直接在 Agent Canvas UI 重新設定 key 即可，本表保留可還原的原值供對照。

### Profile 對照表

| Profile 名稱 | model (litellm) | base_url | 對應 Ollama port | 特色設定 |
|---|---|---|---|---|
| `deepseek-v4-last` | `openai/frob/deepseek-v4-flash-0731:latest` | `http://127.0.0.1:11434/v1` | 11434 | `stream=true`, `extended_thinking_budget=50000` |
| `qwen3.8-27b` | `openai/qwen3.8:27b` | `http://127.0.0.1:11435/v1` | 11435 | `stream=false`, budget=200000 |
| `qwen3.8-sheng` | `openai/qwen3.8:27b` | `http://127.0.0.1:11436/v1` | 11436 | `stream=false`, budget=200000 |
| `qwen3-coder` | `openai/qwen3-coder` | `http://127.0.0.1:11437/v1` | 11437 | `stream=false`, budget=200000 |
| `qwen3-vl-32b` | `openai/qwen3-vl:32b` | `http://127.0.0.1:11438/v1` | 11438 | `stream=true`, `supports_vision=true`, budget=100000 |

### 每個 profile 的常見欄位（除 model/base_url/stream/budget 外皆相同）
```jsonc
{
  "auth_type": "api_key",
  "api_key": "<Fernet 加密字串，換機時重設>",
  "num_retries": 5,
  "retry_multiplier": 8.0,
  "retry_min_wait": 8,
  "retry_max_wait": 64,
  "timeout": 300,
  "max_message_chars": 30000,
  "api_mode": "auto",
  "drop_params": true,
  "modify_params": true,
  "disable_vision": false,
  "disable_stop_word": false,
  "caching_prompt": true,
  "native_tool_calling": true,
  "reasoning_effort": "high",
  "enable_encrypted_reasoning": true,
  "prompt_cache_retention": "24h",
  "usage_id": "default",
  "schema_version": 1
}
```

### 現行設定（`~/.openhands/settings.json`）
- `active_profile`: **`qwen3.8-27b`**
- `active_agent_profile_id`: `41fc4be1-fd05-4ca6-ae2e-8304fa9698a3`（default agent）
- agent: `CodeActAgent`（agent_kind=openhands，schema_version 5）
- 主要 llm（settings 內嵌）: `openai/qwen3.8:27b` @ `http://127.0.0.1:11435/v1`
- condenser: enabled, `max_size=240`, kind=`llm_summarizing`, keep_first=2
- 啟用技能：add-skill / agent-canvas-environment / agent-memory / agent-sdk-builder /
  code-review / docker / github / openhands-api / openhands-automation / openhands-sdk / skill-creator

---

## 4. 關鍵環境變數（還原用）

```bash
export OLLAMA_HOST=0.0.0.0:11434      # 對外部開放（依實際 port 調整 11434~11438）
export OLLAMA_MODELS=/mnt/ollama_models
# OpenHands / Agent Canvas
# AGENT_SERVER_URL=http://127.0.0.1:18000
# 各 agent-server frontend 需 --session-api-key（啟動時由 runtime 注入）
```

---

## 5. 換機還原步驟（摘要）

1. **裝 GPU driver + CUDA 12.8 + Ollama 0.33.2**（3× B200）。
2. **還原模型檔** `~/.ollama/models`（或 `/mnt/ollama_models`）：
   - `qwen3-coder` / `frob/deepseek-v4-flash-0731` / `qwen3.8:27b` / `qwen3-vl:32b`
   - 或用 `ollama pull`：
     ```bash
     ollama pull qwen3-coder
     ollama pull qwen3.8:27b
     ollama pull qwen3-vl:32b
     # frob/deepseek-v4-flash-0731 為客製 fork，需從 `~/.ollama/models/manifests` 搬
     ```
3. **起 5 個 Ollama 實體**，各自綁 port（例）：
   ```bash
   # 每個獨立 OLLAMA_HOST=0.0.0.0:PORT + 獨立 OLLAMA_MODELS 目錄
   OLLAMA_HOST=0.0.0.0:11434 ollama serve &   # deepseek
   OLLAMA_HOST=0.0.0.0:11435 ollama serve &   # qwen3.8-27b (ctx 65536)
   OLLAMA_HOST=0.0.0.0:11436 ollama serve &   # qwen3.8-sheng (ctx 131072)
   OLLAMA_HOST=0.0.0.0:11437 ollama serve &   # qwen3-coder
   OLLAMA_HOST=0.0.0.0:11438 ollama serve &   # qwen3-vl-32b
   ```
   > 若只想跑單 port，把模型指向同一台、改 base_url 即可。
4. **裝 OpenHands SDK 1.44.0**（`openhands-agent-server` / `sdk` / `tools` / `workspace`）。
5. **起 Agent Canvas**：
   ```bash
   node /usr/bin/agent-canvas --port 3000   # ingress
   # 內部會帶起 agent-server(18000) / frontend(3001) / automation(18001)
   ```
6. **在 UI 重建 5 支 LLM profile**（名稱 / base_url / model / 參照本文第 3 節），
   重設 `api_key` 即可（Fernet key 是機器綁定，不必搬）。
7. 驗證：
   ```bash
   for p in 11434 11435 11436 11437 11438; do
     echo "== $p =="; curl -s localhost:$p/api/ps; curl -s localhost:$p/api/version; echo;
   done
   ```

---

## 6. 原始設定檔（供一一還原）

- `profiles/*.json` — 5 支 LLM profile 的**原始 JSON**（含加密 `api_key`）。
- `profiles/agent-profile-default.json` — default agent profile（指向 `deepseek-v4-last`）。
- `settings.json` — 完整 `~/.openhands/settings.json` 快照。

> 新機裝好 SDK 後，直接把这些 JSON 放回對應目錄即可：
> - `profiles/*.json`  → `~/.openhands/profiles/`
> - `profiles/agent-profile-default.json` → `~/.openhands/agent-profiles/default.json`
> - `settings.json` → `~/.openhands/settings.json`
> ⚠️ `api_key` 是機器綁定的 Fernet 加密值，換機後建議在 UI 重設。

---

## 7. 注意事項

- `frob/deepseek-v4-flash-0731` 是**客製 fork**，官方 registry 沒有，務必隨 `~/.ollama/models` 一起搬（含 `manifests/`）。
- 每個 Ollama 綁定特定 GGUF blob（`sha256-...`），`llama-server` 參數（ctx/speculate/mmproj）依模型而異，搬模型時連參數一起記（見上表）。
- `api_key` 為機器綁定的加密值，換機後在 UI 重設即可，**不要把明文 key 放到 git**。
- 本機 `GITHUB_TOKEN` 為 401（無效）；實際可用 credential 為帳號 **`wistroneq3300`**（`~/.git-credentials`）。
