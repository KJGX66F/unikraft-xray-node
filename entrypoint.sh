#!/bin/sh
# 容器启动时用环境变量生成 xray 配置，再启动 xray。
# UUID / WS_PATH / XHTTP_PATH 由 deploy.sh 在 `unikraft run -e` 里传入，不写进镜像。
# 端口：8080 = VLESS+WS（主用），8081 = VLESS+XHTTP（备用）。
# 平台在外层终结 TLS 再以明文 HTTP 转进来，所以 xray 两个入站都不开 TLS、不放证书：
#   443:8080/http+tls  -> WS 入站（HTTP 模式，支持 WS Upgrade）
#   8443:8081/tls      -> XHTTP 入站（TCP 模式，TLS 终结后转发明文 HTTP；8443 只能用 tls，不能加 http）
# XHTTP 服务端 mode 用 auto（接受 packet-up / stream-up / stream-one），
# 客户端链接统一用 packet-up：对 CDN / 反向代理兼容性最高，CF 前置也走这条。
set -eu

UUID="${UUID:?必须设置 UUID 环境变量}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"

mkdir -p /etc/xray
cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 8080,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "port": 8081,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF

echo "[entrypoint] xray listening on 8080 (ws ${WS_PATH}) and 8081 (xhttp ${XHTTP_PATH})"
exec /usr/local/bin/xray run -c /etc/xray/config.json
