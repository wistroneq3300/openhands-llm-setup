#!/bin/bash
# gen-cert.sh — 產生 OpenHands Canvas HTTPS relay 的自簽 TLS 憑證
#
# 用途：openhands-https.service 需要 /opt/openhands-https/certs/{cert,key}.pem。
#       這是自簽憑證（瀏覽器會跳不安全警告，需手動放行）。
# 用法：
#   ./gen-cert.sh <LAN-IP1> [<LAN-IP2> ...]     # 把要訪問的 IP 都寫進 SAN
# 例：
#   ./gen-cert.sh 10.35.229.17 10.33.33.95
#
# 產出路徑：/opt/openhands-https/certs/{cert.pem,key.pem}
set -euo pipefail

CERT_DIR=${CERT_DIR:-/opt/openhands-https/certs}
[ $# -ge 1 ] || { echo "用法: $0 <LAN-IP1> [<LAN-IP2> ...]（至少一個 IP，會寫進 SAN）"; exit 1; }

for a in "$@"; do
  [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "不是合法 IP: $a"; exit 1; }
done

mkdir -p "$CERT_DIR"

# 組 SAN（IP + localhost）
IPS=("$@")
SAN="IP:127.0.0.1,DNS:localhost"
for ip in "${IPS[@]}"; do
  SAN="$SAN,IP:$ip"
done

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -subj "/CN=OpenHands Canvas Self-Signed" \
  -addext "subjectAltName=$SAN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"

chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/cert.pem"
echo "OK: $CERT_DIR/cert.pem（SAN=$SAN）"
echo "下一步：把 https-proxy.js 放到 /opt/openhands-https/ 並 enable 服務（見 README / deploy-https.sh）"
