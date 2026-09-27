#!/bin/bash
# restore-on-new-machine.sh — 換新機一鍵還原（vLLM + Agent Canvas + HTTPS）
#
# 目標：在新機器上把「OpenHands / Agent Canvas + 3× vLLM」一次拉起。
# 流程（盡量可重跑、冪等）：
#   1) 檢查並裝 GPU driver / CUDA 13.0 / python venv + vllm
#   2) 抓 HF 模型（deepseek-v4-flash / qwen3.8-27b / qwen3-vl）
#   3) 部署 3 支 vLLM systemd unit + HTTPS relay（systemd/ + https/）
#   4) 還原 ~/.openhands/profiles 與 settings.json
#   5) 裝 OpenHands SDK 與 agent-canvas
#   6) 起 Agent Canvas + HTTPS relay
#
# 用法:
#   ./restore-on-new-machine.sh [步驟編號或 -a/--all]
#   例：
#     ./restore-on-new-machine.sh --all                 # 全跑（含抓模型）
#     ./restore-on-new-machine.sh 3                     # 只跑步驟 3（部署 systemd）
#     ./restore-on-new-machine.sh verify                # 檢查 8000~8002 + :3000 + :3443
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT_SRC="${SCRIPT_DIR}/systemd"
PROFILE_SRC="${SCRIPT_DIR}/profiles"
SETTINGS_SRC="${SCRIPT_DIR}/settings.json"
HTTPS_SRC="${SCRIPT_DIR}/https"
HTTPS_DIR=/opt/openhands-https

# ---- 可調整預設 ----
VENV_DIR="${VENV_DIR:-/mnt/venv}"            # vllm venv（vllm 0.28.0）
HF_CACHE="${HF_CACHE:-/mnt/hf-cache}"        # HF_HOME
CUDA_HOME_VALUE="${CUDA_HOME_VALUE:-/usr/local/cuda-13.0}"
SDK_VERSION="1.44.0"
AGENT_CANVAS_CMD="node /usr/bin/agent-canvas --port 3000"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-qwen3.8-27b}"
LAN_IPS=()                                    # HTTPS 憑證 SAN -> 跑 --all 時由 --ips 帶入

info()  { printf '\033[1;32m>>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "請用 root 執行（或 sudo 本腳本）。"; }

# == 1. GPU driver / CUDA / venv + vllm ==
step1() {
  need_root
  info "STEP 1: GPU driver / CUDA / python venv + vllm"
  nvidia-smi >/dev/null 2>&1 && info "  nvidia driver OK: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)" \
    || warn "  未偵測到 nvidia-smi，請先安裝 NVIDIA driver + CUDA 13.0（7× B200）。"

  if [ -x "$VENV_DIR/bin/vllm" ]; then
    info "  vllm 已存在: $($VENV_DIR/bin/vllm --version 2>&1 | head -1)"
  else
    info "  建立 venv 並安裝 vllm（此步較久）..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install vllm==0.28.0 || warn "  vllm 安裝失敗，請確認 CUDA/python 版本"
  fi
}

# == 2. HF 模型 ==
step2() {
  need_root
  info "STEP 2: 抓取 HF 模型（HF_HOME=$HF_CACHE）"
  mkdir -p "$HF_CACHE"
  "$VENV_DIR/bin/huggingface-cli" --version >/dev/null 2>&1 || "$VENV_DIR/bin/pip" install -U "huggingface_hub[cli]" || true
  local m
  for m in \
    "deepseek-ai/DeepSeek-V4-Flash-0731" \
    "Qwen/Qwen3.8-27B" \
    "Qwen/Qwen3-VL-30B-A3B-Instruct"; do
    info "  download $m"
    HF_HOME="$HF_CACHE" "$VENV_DIR/bin/huggingface-cli" download "$m" || warn "  $m 下載失敗"
  done
}

# == 3. 部署 systemd（3× vLLM + HTTPS relay）==
step3() {
  need_root
  [ -d "$UNIT_SRC" ] || die "找不到 $UNIT_SRC"
  info "STEP 3: 部署 systemd（3× vLLM + openhands-https）"
  local u
  for u in deepseek-v4-0731 qwen3-27b qwen3-vl openhands-https; do
    install -m 0644 "$UNIT_SRC/$u.service" "/etc/systemd/system/$u.service"
  done
  systemctl daemon-reload
  for u in deepseek-v4-0731 qwen3-27b qwen3-vl; do
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u"
    info "  $u -> $(systemctl is-active "$u")"
  done

  # HTTPS relay（proxy.js + certs + service）
  info "STEP 3b: 部署 HTTPS relay（:3443 -> :3000）"
  mkdir -p "$HTTPS_DIR"
  install -m 0644 "$HTTPS_SRC/https-proxy.js" "$HTTPS_DIR/https-proxy.js"
  install -m 0644 "$UNIT_SRC/openhands-https.service" /etc/systemd/system/openhands-https.service
  if [ ! -f "$HTTPS_DIR/certs/cert.pem" ]; then
    if [ ${#LAN_IPS[@]} -gt 0 ]; then
      "$HTTPS_SRC/gen-cert.sh" "${LAN_IPS[@]}"
    else
      warn "  沒有指定 LAN IP，用 localhost 產生憑證；之後可重跑 gen-cert.sh 補 IP"
      "$HTTPS_SRC/gen-cert.sh" 127.0.0.1
    fi
  fi
  systemctl daemon-reload
  systemctl enable openhands-https.service >/dev/null 2>&1 || true
  systemctl restart openhands-https.service
  info "  openhands-https -> $(systemctl is-active openhands-https.service)"
}

# == 4. 還原 profiles & settings ==
step4() {
  need_root
  [ -d "$PROFILE_SRC" ] || die "找不到 $PROFILE_SRC"
  info "STEP 4: 還原 ~/.openhands profiles & settings"
  local U="${SUDO_USER:-$(stat -c %U "$HOME" 2>/dev/null || echo root)}"
  local OPENHANDS_HOME
  OPENHANDS_HOME="$(eval echo "~$U")/.openhands"
  mkdir -p "$OPENHANDS_HOME/profiles"
  install -m 600 "$PROFILE_SRC"/*.json "$OPENHANDS_HOME/profiles/"
  [ -f "$SETTINGS_SRC" ] && install -m 600 "$SETTINGS_SRC" "$OPENHANDS_HOME/settings.json"
  chown -R "$U" "$OPENHANDS_HOME" 2>/dev/null || true
  warn "  api_key 是 Fernet 機器綁定值（repo 內為佔位碼）。換機後請在 Agent Canvas UI"
  warn "  重設 3 支 LLM 的 key（deepseek-v4-flash / qwen3.8-27b / qwen3-vl-32b）。"
}

# == 5. OpenHands SDK + agent-canvas ==
step5() {
  need_root
  info "STEP 5: 安裝 OpenHands SDK $SDK_VERSION + agent-canvas"
  pip install --upgrade "openhands-sdk==$SDK_VERSION" "openhands-tools==$SDK_VERSION" || warn "  pip install 失敗"
  command -v agent-canvas >/dev/null 2>&1 || npm install -g agent-canvas || \
    warn "  沒有 agent-canvas，請依照 Agent Canvas 文件安裝到 /usr/bin/agent-canvas"
}

# == 6. 起 Agent Canvas ==
step6() {
  need_root
  info "STEP 6: 起 Agent Canvas（ingress :3000）"
  if pgrep -f 'agent-canvas --port 3000' >/dev/null 2>&1; then
    info "  agent-canvas 已在跑"
  else
    nohup $AGENT_CANVAS_CMD >/var/log/agent-canvas.log 2>&1 &
    sleep 3
    pgrep -f 'agent-canvas --port 3000' >/dev/null 2>&1 && info "  agent-canvas 已啟動" || warn "  啟動失敗，看 /var/log/agent-canvas.log"
  fi
}

verify() {
  info "VERIFY: 3× vLLM + Agent Canvas + HTTPS"
  for p in 8000 8001 8002; do
    printf '  :%-5s %s\n' "$p" "$(curl -fsS --max-time 5 "http://localhost:$p/v1/models" 2>/dev/null | head -c 200 || echo '<no response>')"
  done
  curl -fsS --max-time 5 http://localhost:3000/api/health >/dev/null 2>&1 && echo "  ingress :3000 OK" || echo "  ingress :3000 未就緒"
  curl -sk --max-time 5 -o /dev/null -w "  https :3443 -> %{http_code}\n" "https://127.0.0.1:3443/" 2>/dev/null || echo "  https :3443 未就緒"
}

show_usage() {
  cat <<'EOF'
restore-on-new-machine.sh — vLLM 換新機一鍵還原

用法: ./restore-on-new-machine.sh [step|--all|verify] [--ips IP...]
  --all        依序跑 1→2→3→4→5→6
  <N>          只跑單一步驟（1..6）
  verify       檢查 vLLM 3 port + ingress + HTTPS
  --ips A B C  把 LAN IP 寫進 HTTPS 自簽憑證 SAN（step3 用）

步驟：
  1  GPU driver / CUDA 13.0 / python venv + vllm 0.28.0
  2  HF 模型（deepseek-v4-flash / qwen3.8-27b / qwen3-vl）
  3  部署並啟動 3× vLLM systemd + HTTPS relay
  4  還原 ~/.openhands/profiles 與 settings.json
  5  裝 OpenHands SDK 1.44.0 + agent-canvas
  6  起 Agent Canvas（:3000）
EOF
}

# 解析 --ips
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ips) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do LAN_IPS+=("$1"); shift; done ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"

if [ $# -eq 0 ]; then show_usage; exit 0; fi
case "$1" in
  --all|-a) for s in step1 step2 step3 step4 step5 step6; do "$s"; done; verify ;;
  verify)   verify ;;
  [1-6])    step"$1" ;;
  *)        show_usage; exit 1 ;;
esac
