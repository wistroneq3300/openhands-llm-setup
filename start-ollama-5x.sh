#!/bin/bash
# start-ollama-5x.sh
# 一鍵管理 5 個 Ollama 實體（ol-flash / ol-qwen27 / ol-qwen27b / ol-coder / ol-qwenvl）。
# 參考自 root 下的 llm.sh，並加上「從本 repo 自動部署 systemd unit」的能力。
# 可在舊機或用來在新機快速拉起（restore-on-new-machine.sh 會呼叫 deploy 部分）。
set -euo pipefail

# === 自動定位 repo 內的 systemd/ 目錄（不依賴 PWD） ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="${SCRIPT_DIR}/systemd"

UNITS=(ol-flash:11434 ol-qwen27:11435 ol-qwen27b:11436 ol-coder:11437 ol-qwenvl:11438)

api_ps() {
  local port="$1"
  curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/ps" || true
  echo
}

# === 把本 repo 的 unit 佈署到 systemd 並 enable ===
deploy_units() {
  [ -d "$UNIT_SRC" ] || { echo "找不到 $UNIT_SRC（請確認 start-ollama-5x.sh 與 systemd/ 同層）"; return 1; }
  echo '==> 部署 5 支 Ollama systemd 服務...'
  local u d
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    sudo install -m 0644 "$UNIT_SRC/$u.service" "/etc/systemd/system/$u.service"
    d="$UNIT_SRC/$u.service.d"
    if [ -d "$d" ]; then
      sudo mkdir -p "/etc/systemd/system/$u.service.d"
      sudo install -m 0644 "$d"/*.conf "/etc/systemd/system/$u.service.d/"
    fi
  done
  sudo systemctl daemon-reload
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    sudo systemctl enable "$u" >/dev/null 2>&1 || true
  done
  echo '==> 部署完成。可用選項 4 或 5 啟動。'
}

# === 拉起全部（enable + start） ===
start_all_units() {
  echo '==> enable + start 五個服務...'
  local u
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    sudo systemctl enable "$u" >/dev/null 2>&1 || true
    sudo systemctl start "$u"
    echo "  $u -> $(sudo systemctl is-active "$u")"
  done
}

warmup() {
  echo '==> 11435 qwen3.8:27b (27B-A, 65K)'
  curl -sS --max-time 180 http://127.0.0.1:11435/api/generate \
    -d '{"model":"qwen3.8:27b","prompt":"hi","keep_alive":"24h","stream":false}'
  echo

  echo '==> 11436 qwen3.8:27b (27B-B, 128K)'
  curl -sS --max-time 240 http://127.0.0.1:11436/api/generate \
    -d '{"model":"qwen3.8:27b","prompt":"hi","keep_alive":"24h","stream":false}'
  echo

  echo '==> 11437 qwen3-coder'
  curl -sS --max-time 180 http://127.0.0.1:11437/api/generate \
    -d '{"model":"qwen3-coder:latest","prompt":"hi","keep_alive":"24h","stream":false}'
  echo

  echo '==> 11438 qwen3-vl'
  curl -sS --max-time 180 http://127.0.0.1:11438/api/generate \
    -d '{"model":"qwen3-vl:32b","prompt":"hi","keep_alive":"24h","stream":false}'
  echo

  echo '==> 11434 Flash (較久)'
  curl -sS --max-time 600 http://127.0.0.1:11434/api/generate \
    -d '{"model":"frob/deepseek-v4-flash-0731:latest","prompt":"hi","keep_alive":"24h","stream":false}'
  echo

  status
}

status() {
  echo '=== Loaded models (/api/ps) ==='
  local name port
  for item in '11434 Flash' '11435 Qwen-27B-A' '11436 Qwen-27B-B' '11437 Qwen-Coder' '11438 Qwen-VL'; do
    set -- $item
    printf '\n--- %s (%s) ---\n' "$2" "$1"
    api_ps "$1"
  done

  echo '=== Service status ==='
  local u
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    printf '  %-16s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo inactive)"
  done

  echo '=== GPU status ==='
  nvidia-smi
}

restart_svc() {
  echo '這會 unload 所有五個模型並中斷使用中的請求；重啟後需再跑選項 1 預熱。'
  read -r -p '確定 restart 五個服務？[y/N] ' ans
  [[ "${ans:-}" =~ ^[yY]$ ]] || { echo '取消'; return; }
  sudo systemctl restart ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl
  local u
  for u in ol-flash ol-qwen27 ol-qwen27b ol-coder ol-qwenvl; do
    printf '  %-16s %s\n' "$u" "$(sudo systemctl is-active "$u")"
  done
  sudo ss -lntp 2>/dev/null | grep -E ':(11434|11435|11436|11437|11438)\b' || true
}

restart_one() {
  echo '1) Flash / 11434'
  echo '2) Qwen 27B-A / 11435'
  echo '3) Qwen 27B-B / 11436'
  echo '4) Qwen Coder / 11437'
  echo '5) Qwen VL / 11438'
  read -r -p '選要 restart 的服務 [1-5]: ' choice

  local target=''
  case "$choice" in
    1) target='ol-flash' ;;
    2) target='ol-qwen27' ;;
    3) target='ol-qwen27b' ;;
    4) target='ol-coder' ;;
    5) target='ol-qwenvl' ;;
    *) echo '無效'; return ;;
  esac

  echo "這會中斷 $target 的使用者請求，並卸載該服務模型。"
  read -r -p "確定 restart $target？[y/N] " ans
  [[ "${ans:-}" =~ ^[yY]$ ]] || { echo '取消'; return; }
  sudo systemctl restart "$target"
  sudo systemctl status "$target" --no-pager -l 2>/dev/null | sed -n '1,12p'
}

while true; do
  echo
  echo '1) 預熱五個模型（curl keep_alive）'
  echo '2) 查看模型、服務與 GPU 狀態'
  echo '3) 部署/更新 systemd 服務（從本 repo）'
  echo '4) start 全部五個服務'
  echo '5) restart 單一服務'
  echo '6) restart 全部五個服務'
  echo 'q) 離開'
  read -r -p '選: ' c
  case "$c" in
    1) warmup ;;
    2) status ;;
    3) deploy_units ;;
    4) start_all_units ;;
    5) restart_one ;;
    6) restart_svc ;;
    q|Q) exit 0 ;;
    *) echo '無效' ;;
  esac
done
