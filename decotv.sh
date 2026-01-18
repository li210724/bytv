#!/usr/bin/env bash
set -e

APP="DecoTV v3"
BASE="/opt/decotv"
NET="decotv-net"
COMPOSE="$BASE/docker-compose.yml"
NGINX_CONF="/etc/nginx/conf.d/decotv.conf"

need_root() {
  [[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
}

pause() { read -rp "按 Enter 继续..."; }

has() { command -v "$1" &>/dev/null; }

install_base() {
  if ! has docker; then
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker --now
  fi
  if ! has docker-compose; then
    curl -L https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-$(uname -s)-$(uname -m) \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
  apt install -y jq dnsutils >/dev/null 2>&1
}

# ---------------- Cloudflare DNS ----------------
cf_ip() { curl -s ipv4.icanhazip.com; }

cf_api() {
  curl -s -X "$1" "https://api.cloudflare.com/client/v4$2" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$3"
}

cf_sync() {
  IP=$(cf_ip)
  ZONE_ID=$(cf_api GET "/zones?name=$CF_ZONE" | jq -r '.result[0].id')
  [[ "$ZONE_ID" == "null" ]] && echo "❌ CF Zone 不存在" && exit 1

  RID=$(cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" | jq -r '.result[0].id')

  DATA="{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":false}"

  if [[ "$RID" == "null" ]]; then
    echo "➕ 创建 DNS 记录"
    cf_api POST "/zones/$ZONE_ID/dns_records" "$DATA" >/dev/null
  else
    echo "♻️ 更新 DNS 记录"
    cf_api PUT "/zones/$ZONE_ID/dns_records/$RID" "$DATA" >/dev/null
  fi

  sleep 5
  [[ "$(dig +short $DOMAIN | tail -n1)" != "$IP" ]] && echo "❌ DNS 校验失败" && exit 1
  echo "✅ Cloudflare 解析完成"
}

# ---------------- Deploy ----------------
deploy() {
  read -rp "域名 (tv.example.com): " DOMAIN
  read -rp "管理员账号: " USER
  read -rp "管理员密码: " PASS

  read -rp "启用 Cloudflare 自动解析？(y/n): " CF
  if [[ "$CF" == "y" ]]; then
    read -rp "CF 主域名(example.com): " CF_ZONE
    read -rp "CF API Token: " CF_TOKEN
    cf_sync
  fi

  install_base

  mkdir -p "$BASE"
  docker network inspect "$NET" &>/dev/null || docker network create "$NET"

  cat >"$COMPOSE" <<EOF
version: "3.9"
services:
  decotv:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-app
    restart: unless-stopped
    environment:
      - USERNAME=$USER
      - PASSWORD=$PASS
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kv:6666
    ports:
      - "127.0.0.1:3000:3000"
    networks: [$NET]

  kvrocks:
    image: apache/kvrocks
    container_name: decotv-kv
    restart: unless-stopped
    volumes:
      - kv-data:/var/lib/kvrocks
    networks: [$NET]

volumes:
  kv-data:

networks:
  $NET:
    external: true
EOF

  docker-compose -f "$COMPOSE" up -d

  cat >"$NGINX_CONF" <<EOF
server {
  listen 80;
  server_name $DOMAIN;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF

  nginx -t && systemctl reload nginx
  echo "🎉 部署完成：http://$DOMAIN"
}

update_app() {
  docker-compose -f "$COMPOSE" pull
  docker-compose -f "$COMPOSE" up -d
  echo "✅ 更新完成"
}

uninstall() {
  read -rp "确认卸载 DecoTV？(yes): " OK
  [[ "$OK" != "yes" ]] && return
  docker-compose -f "$COMPOSE" down -v || true
  docker network rm "$NET" 2>/dev/null || true
  rm -rf "$BASE"
  rm -f "$NGINX_CONF"
  nginx -t && systemctl reload nginx
  echo "🗑️ 已卸载（原系统无影响）"
}

install_cli() {
  cp "$0" /usr/local/bin/decotv
  chmod +x /usr/local/bin/decotv
  echo "✅ 已安装快捷命令：decotv"
}

need_root
while true; do
  clear
  echo "==== $APP 管理面板 ===="
  echo "1. 一键部署（零冲突）"
  echo "2. 更新镜像"
  echo "3. 启动服务"
  echo "4. 停止服务"
  echo "5. 卸载"
  echo "6. 安装快捷命令"
  echo "0. 退出"
  read -rp "选择: " C
  case $C in
    1) deploy; pause ;;
    2) update_app; pause ;;
    3) docker-compose -f "$COMPOSE" up -d; pause ;;
    4) docker-compose -f "$COMPOSE" down; pause ;;
    5) uninstall; pause ;;
    6) install_cli; pause ;;
    0) exit ;;
  esac
done
