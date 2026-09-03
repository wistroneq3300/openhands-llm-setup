#!/bin/bash
# restore-on-new-machine.sh — 換新機一鍵還原
#
# 目標：在新機器上把「OpenHands / Agent Canvas + 5× Ollama」一次拉起。
# 流程（盡量可重跑、冪等）：
#   1) 檢查並裝 GPU driver / CUDA / Ollama
#   2) ollama pull 你要的模型（frob/deepseek 為客製 fork，另處理）
#   3) 部署 5 支 systemd unit（systemd/ 目錄）
#   4) 還原 ~/.openhands/profiles 與 settings.json
#   5) 裝 OpenHands SDK 1.44.0 與 agent-canvas
#   6) 起 Agent Canvas
#
# 用法:
#   ./restore-on-new-machine.sh [步驟編號或 -a/--all]
#   例：
#     ./restore-on-new-machine.sh --all                 # 全跑（含 pull 模型）
#     ./restore-on-new-machine.sh 3                     # 只跑步驟 3（部署 systemd）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 從 REPO_NAME 可改；預設使用本 repo 的 systemd/ 與 profiles/
UNIT_SRC="${SCRIPT_DIR}/systemd"
PROFILE_SRC="${SCRIPT_DIR}/profiles"
SETTINGS_SRC="${SCRIPT_DIR}/settings.json"

# ---- 可調整預設 ----
OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
OLLAMA_VERSION="${OLLAMA_VERSION:-0.33.2}"
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-/mnt/ollama_models}"
SDK_VERSION="1.44.0"
AGENT_CANVAS_CMD="node /usr/bin/agent-canvas --port 3000"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-qwen3.8-27b}"   # 還原後 active_profile

info()  { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "請用 root 執行（或 sudo 本腳本）。"; }

# ==== 1. GPU / CUDA / Ollama ====
step1() {
  need_root
  info "STEP 1: GPU driver / CUDA / Ollama $OLLAMA_VERSION"
  nvidia-smi >/dev/null 2>&1 && info "  nvidia driver OK: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)" \
    || warn "  未偵測到 nvidia-smi，請先安裝 3× B200 的 NVIDIA driver + CUDA 12.8。"

  if [ -x "$OLLAMA_BIN" ]; then
    info "  Ollama 已存在: $($OLLAMA_BIN --version 2>&1 | head -1)"
  else
    info "  安裝 Ollama $OLLAMA_VERSION ..."
    curl -fsSL https://ollama.com/install.sh | sh   # 裝最新版，之後可覆蓋到指定版
  fi
}

# ==== 2. ollama pull 模型 ====
step2() {
  need_root
  info "STEP 2: ollama pull 模型"
  mkdir -p "$OLLAMA_MODELS_DIR"; chown ollama:ollama "$OLLAMA_MODELS_DIR" 2>/dev/null || true
  local m
  for m in qwen3-coder qwen3.8:27b qwen3-vl:32b; do
    info "  pull $m"
    sudo -u ollama OLLAMA_MODELS="$OLLAMA_MODELS_DIR" "$OLLAMA_BIN" pull "$m" || warn "  pull $m 失敗"
  done
  warn "  frob/deepseek-v4-flash-0731 是客製 fork，官方沒有。"
  warn "  請把舊機的 ~/.ollama/models 整包（含 manifests/）搬到 $OLLAMA_MODELS_DIR，"
  warn "  或在 UI 改成你的其它模型。"
}

# ==== 3. 部署 5 支 systemd unit ====
step3() {
  need_root
  [ -d "$UNIT_SRC" ] || die "找不到 $UNIT_SRC"
  info "STEP 3: 部署 systemd 服務（從 systemd/）"
  local u d
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    install -m 0644 "$UNIT_SRC/$u.service" "/etc/systemd/system/$u.service"
    d="$UNIT_SRC/$u.service.d"
    if [ -d "$d" ]; then
      mkdir -p "/etc/systemd/system/$u.service.d"
      install -m 0644 "$d"/*.conf "/etc/systemd/system/$u.service.d/"
    fi
  done
  systemctl daemon-reload
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u"
    info "  $u -> $(systemctl is-active "$u")"
  done
}

# ==== 4. 還原 profiles & settings ====
step4() {
  need_root
  [ -d "$PROFILE_SRC" ] || die "找不到 $PROFILE_SRC"
  info "STEP 4: 還原 ~/.openhands profiles & settings"
  local U="${SUDO_USER:-$HOME_USER}"
  U="${U:-$(stat -c %U "$HOME" 2>/dev/null || echo root)}"
  local OPENHANDS_HOME
  OPENHANDS_HOME="$(eval echo "~$U")/.openhands"
  mkdir -p "$OPENHANDS_HOME/profiles" "$OPENHANDS_HOME/agent-profiles"

  install -m 600 "$PROFILE_SRC"/*.json "$OPENHANDS_HOME/profiles/"
  # default agent profile（若有）
  [ -f "$PROFILE_SRC/agent-profile-default.json" ] && \
    install -m 600 "$PROFILE_SRC/agent-profile-default.json" "$OPENHANDS_HOME/agent-profiles/default.json"
  # settings.json（含 active_profile / active_agent_profile_id）
  [ -f "$SETTINGS_SRC" ] && install -m 600 "$SETTINGS_SRC" "$OPENHANDS_HOME/settings.json"
  chown -R "$U" "$OPENHANDS_HOME" 2>/dev/null || true

  warn "  api_key 是 Fernet 機器綁定值，換機後請在 Agent Canvas UI 重設 5 支 LLM 的 key。"
  warn "  若只復原其中 3 支（qwen3-coder/qwen3.8:27b/qwen3-vl:32b），請把設定檔對應改到實際在跑的 port。"
}

# ==== 5. OpenHands SDK + agent-canvas ====
step5() {
  need_root
  info "STEP 5: 安裝 OpenHands SDK $SDK_VERSION + agent-canvas"
  pip install --upgrade "openhands-sdk==$SDK_VERSION" "openhands-tools==$SDK_VERSION" || warn "  pip install 失敗，請確認 python/pip"
  command -v agent-canvas >/dev/null 2>&1 || npm install -g agent-canvas || \
    warn "  沒有 agent-canvas，請依照 Agent Canvas 文件安裝到 /usr/bin/agent-canvas"
}

# ==== 6. 起 Agent Canvas ====
step6() {
  need_root
  info "STEP 6: 起 Agent Canvas (ingress :3000)"
  if pgrep -f 'agent-canvas --port 3000' >/dev/null 2>&1; then
    info "  agent-canvas 已在跑"
  else
    nohup $AGENT_CANVAS_CMD >/var/log/agent-canvas.log 2>&1 &
    sleep 3
    pgrep -f 'agent-canvas --port 3000' >/dev/null 2>&1 && info "  agent-canvas 已啟動 (log: /var/log/agent-canvas.log)" || warn "  起動失敗，看 /var/log/agent-canvas.log"
  fi
}

verify() {
  info "VERIFY: 檢查 5 個 Ollama port + Agent Canvas"
  for p in 11434 11435 11436 11437 11438; do
    printf '  %-6s %s\n' "$p" "$(curl -fsS --max-time 5 "http://localhost:$p/api/ps" 2>/dev/null | head -c 300 || echo '<no response>')"
  done
  curl -fsS --max-time 5 http://localhost:3000/api/health >/dev/null 2>&1 && echo "  ingress :3000 OK" || echo "  ingress :3000 未就緒"
}

show_usage() {
  cat <<'EOF'
restore-on-new-machine.sh — 換新機一鍵還原

用法: ./restore-on-new-machine.sh [step|--all|verify]
  --all        依序跑 1→2→3→4→5→6
  <N>          只跑單一步驟（1..6）
  verify       檢查 5 port + ingress
  (無參數)      顯示此說明

步驟：
  1  GPU driver / CUDA / Ollama
  2  ollama pull 模型（qwen3-coder, qwen3.8:27b, qwen3-vl:32b；fork 另外搬）
  3  部署並啟動 5 支 systemd 服務
  4  還原 ~/.openhands/profiles 與 settings.json
  5  裝 OpenHands SDK 1.44.0 + agent-canvas
  6  起 Agent Canvas (:3000)
EOF
}

if [ $# -eq 0 ]; then show_usage; exit 0; fi
case "$1" in
  --all|-a) for s in step1 step2 step3 step4 step5 step6; do "$s"; done; verify ;;
  verify)   verify ;;
  [1-6])    step"$1" ;;
  *)        show_usage; exit 1 ;;
esac
