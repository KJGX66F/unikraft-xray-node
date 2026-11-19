#!/usr/bin/env bash
# Unikraft Cloud xray VLESS 节点一键部署：WS 主用 + XHTTP 备用，直连 + CF 双链
# 用法：
#   ./deploy.sh <你的 Unikraft 组织名>                                  # 默认：本地从 Dockerfile 构建
#   ./deploy.sh <你的 Unikraft 组织名> --from-ghcr [GHCR 镜像地址]      # 用 GitHub 打好的镜像部署
#     不填镜像地址时默认 ghcr.io/kjgx66f/unikraft-xray-node:latest（主仓库的镜像）；
#     fork 后用自己的镜像：./deploy.sh <org> --from-ghcr ghcr.io/<你的用户名>/<仓库名>:latest
#     也可以用环境变量：GHCR_IMAGE=ghcr.io/<你的用户名>/<仓库名>:latest ./deploy.sh <org> --from-ghcr
#   组织名在 unikraft.com 注册后可见（登录后右上角，或 `unikraft login` 成功后显示）。
#   metro 默认 sin（新加坡，离国内最近）；要换城市：METRO=fra ./deploy.sh <org>
# 流程：生成 UUID + 随机 WS/XHTTP 路径 -> build 镜像 -> run 实例 -> 你粘回平台域名
#       （可选再粘一个已接 CF 的自有域名）-> 生成 4 条链接 + Clash + sing-box。
# 全程不提交任何东西到仓库；UUID 只存在本地 .env.local 和 node-out/ 里。
set -eu
cd "$(dirname "$0")"

ORG="${1:-}"
if [ -z "$ORG" ]; then
  read -rp "输入你的 Unikraft 组织名（org，例如 kjgx）: " ORG
fi
# 镜像名默认取当前文件夹名（也就是仓库名），fork 改名后自动跟着变；
# 想固定成别的名字：IMAGE_NAME=xray-node ./deploy.sh <org>
REPO_NAME="${IMAGE_NAME:-$(basename "$PWD")}"
IMAGE="$ORG/$REPO_NAME:latest"
METRO="${METRO:-sin}"

# --from-ghcr 模式：用 GitHub Actions 打好的 GHCR 镜像部署，跳过本地从 Dockerfile 构建 xray。
# GHCR 镜像是普通 Docker 镜像，不能直接 unikraft run --image ghcr.io/...（公开云不支持外部镜像直跑），
# 要经 Kraftfile.oci 把它展平成 Unikraft 镜像（仍需本地 BuildKit，但省掉下载 Xray、本地构建这一步）。
FROM_GHCR=0
GHCR_IMAGE="${GHCR_IMAGE:-ghcr.io/kjgx66f/unikraft-xray-node:latest}"
if [ "${2:-}" = "--from-ghcr" ]; then
  FROM_GHCR=1
  if [ -n "${3:-}" ]; then GHCR_IMAGE="$3"; fi
fi

command -v unikraft >/dev/null || { echo "[FAIL] 没找到 unikraft CLI，先按 README 第 1 步装好"; exit 1; }
command -v docker >/dev/null || { echo "[FAIL] 没找到 docker（build 需要 BuildKit，装 Docker Desktop 即可）"; exit 1; }
command -v python3 >/dev/null || { echo "[FAIL] 没找到 python3（生成链接需要）"; exit 1; }

# 1. 生成 UUID + 随机 WS/XHTTP 路径（不存在才生成，已有就复用，避免换一次就换订阅）
if [ -f .env.local ]; then
  echo "[1/4] 已有 .env.local，复用里面的 UUID / WS_PATH / XHTTP_PATH"
else
  UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  WS_PATH="/$(python3 -c 'import secrets; print(secrets.token_urlsafe(6).rstrip("="))')"
  XHTTP_PATH="/$(python3 -c 'import secrets; print(secrets.token_urlsafe(6).rstrip("="))')"
  printf 'UUID=%s\nWS_PATH=%s\nXHTTP_PATH=%s\n' "$UUID" "$WS_PATH" "$XHTTP_PATH" > .env.local
  echo "[1/4] 已生成 UUID + 随机 WS/XHTTP 路径，存在 .env.local（不要公开）"
fi
# shellcheck disable=SC1091
source .env.local
# 兼容旧版 .env.local（只有 WS_PATH，没有 XHTTP_PATH 的情况）
if [ -z "${XHTTP_PATH:-}" ]; then
  XHTTP_PATH="/$(python3 -c 'import secrets; print(secrets.token_urlsafe(6).rstrip("="))')"
  printf 'XHTTP_PATH=%s\n' "$XHTTP_PATH" >> .env.local
  echo "[1/4] 已补生成 XHTTP_PATH"
fi

# 2. 登录（已登录会直接过）
echo "[2/4] 登录 Unikraft Cloud（会打开浏览器）…"
unikraft login

# 3. 构建并推送镜像
if [ "$FROM_GHCR" = "1" ]; then
  echo "[3/4] 用 GHCR 镜像 $GHCR_IMAGE 打包（Kraftfile.oci -> Kraftfile.ghcr）…"
  echo "      私有 GHCR 镜像先登录一次：echo <token> | docker login ghcr.io -u <用户名> --password-stdin"
  sed "s|__GHCR_IMAGE__|$GHCR_IMAGE|g" Kraftfile.oci > Kraftfile.ghcr
  unikraft build -K Kraftfile.ghcr . --output "$IMAGE"
else
  echo "[3/4] 构建镜像 $IMAGE …"
  unikraft build . --output "$IMAGE"
fi

# 4. 创建实例：sin 新加坡，256M 内存（xray 够用），scale-to-zero 关掉（节点要常驻接长连接）
#    443:8080/http+tls = WS 主用；8443:8081/tls = XHTTP 备用（8443 只能用 tls，不能加 http）
echo "[4/4] 创建实例（metro=$METRO，443:8080 WS + 8443:8081 XHTTP，scale-to-zero=off，restart=always）…"
unikraft run --metro "$METRO" \
  --name xray-node \
  -m 256M --vcpus 1 \
  -p 443:8080/http+tls \
  -p 8443:8081/tls \
  --scale-to-zero policy=off \
  --restart always \
  -e "UUID=$UUID" -e "WS_PATH=$WS_PATH" -e "XHTTP_PATH=$XHTTP_PATH" \
  --image "$IMAGE" --follow

echo
echo "实例起来后，从上面输出里复制平台给的域名（形如 xxx.sin.unikraft.app），然后粘贴："
read -rp "域名: " DOMAIN
read -rp "CF 域名（可选，已接 Cloudflare 的自有域名，没有就直接回车）: " CF_DOMAIN || true

if [ -n "${CF_DOMAIN:-}" ]; then
  python3 ./gen_links.py --domain "$DOMAIN" --cf-domain "$CF_DOMAIN" \
    --uuid "$UUID" --ws-path "$WS_PATH" --xhttp-path "$XHTTP_PATH" --out-dir ./node-out
else
  python3 ./gen_links.py --domain "$DOMAIN" \
    --uuid "$UUID" --ws-path "$WS_PATH" --xhttp-path "$XHTTP_PATH" --out-dir ./node-out
  echo
  echo "只生成了直连链。以后接好 CF 域名了，再跑一次就能补 CF 链（UUID/路径不变）："
  echo "  python3 ./gen_links.py --domain \"$DOMAIN\" --cf-domain <你的CF域名> --uuid \"$UUID\" --ws-path \"$WS_PATH\" --xhttp-path \"$XHTTP_PATH\" --out-dir ./node-out"
fi
echo
echo "交付物在 ./node-out/：links.txt（直连+CF 共 2~4 条）、clash.yaml、sing-box.json（只含 WS）"
echo "验收：先用 v2rayNG 导入 links.txt 里第一条 WS 直连，打开 https://www.google.com/generate_204 应返回 204，"
echo "再逐条测 XHTTP 直连和两条 CF 链，晚高峰各测一次，留最快的那条日常用。"
