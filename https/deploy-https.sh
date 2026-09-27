#!/bin/bash
# deploy-https.sh — 部署 OpenHands Canvas HTTPS relay（3443 -> 127.0.0.1:3000）
#
# 做了四件事：
#   1) 產生/檢查自簽憑證（./gen-cert.sh 或已存在）
#   2) 把 https-proxy.js 裝到 /opt/openhands-https/
#   3) 把 openhands-https.service 裝到 /etc/systemd/system/
#   4) systemctl enable + start
#
# 用法：
#   ./deploy-https.sh <LAN-IP>           # 首次部署（含產憑證，把 IP 寫進 SAN）
#   ./deploy-https.sh <LAN-IP> --regen   # 重新產生憑證再部署
#   ./deploy-https.sh                     # 只重裝 proxy+service（憑證沿用現有）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTTPS_DIR=/opt/openhands-https
CERT_DIR=$HTTPS_DIR/certs

need_root() { [ "$(id -u)" = 0 ] || { echo "請用 root 執行"; exit 1; }; }

# 1) 憑證
if [ "${1:-}" != "" ] && { [ ! -f "$CERT_DIR/cert.pem" ] || [ "${2:-}" = "--regen" ]; }; then
  "$SCRIPT_DIR/gen-cert.sh" "$@"
elif [ ! -f "$CERT_DIR/cert.pem" ]; then
  need_root
  echo "沒有現成憑證。請指定 LAN IP："
  echo "  ./deploy-https.sh <LAN-IP>"
  exit 1
fi
need_root

# 2) proxy.js
mkdir -p "$HTTPS_DIR"
install -m 0644 "$SCRIPT_DIR/https-proxy.js" "$HTTPS_DIR/https-proxy.js"

# 3) systemd service
install -m 0644 "$SCRIPT_DIR/../systemd/openhands-https.service" /etc/systemd/system/openhands-https.service
systemctl daemon-reload
systemctl enable openhands-https.service >/dev/null 2>&1 || true

# 4) start
systemctl restart openhands-https.service
sleep 1
systemctl is-active openhands-https.service
echo "完成：https://<你的 LAN IP>:3443 已指向 Agent Canvas (:3000)。"
echo "瀏覽器首次會跳自簽憑證警告，按『繼續前往』即可。"
