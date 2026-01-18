#!/usr/bin/env bash
set -e

# ========== 基础配置 ==========
APP_NAME="DecoTV"
BASE_DIR="/opt/decotv"
NETWORK="decotv-net"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
CADDY_FILE="${BASE_DIR}/Caddyfile"

# ========== 工具函数 ==========
pause() {
  read -rp "按 Enter 继续..."
}

get_ip() {
  curl -s ipv4.icanhazip.com
}

domain_ip() {
  dig +short "$1" | tail -n1
}

check_domain() {
  local domain="$1"
  local local_ip
  local domain_ip_res

  local_ip=$(get_ip)
  domain_ip_res=$(domain_ip "$domain")

  echo "🌐 本机 IP:     $local_ip"
  echo "🌐 域名解析 IP: $domain_ip_res"

  if [[ "$local_ip" != "$domain_ip_res" ]]; then
    echo "❌ 域名未正确解析到本机"
    return 1
  fi
  echo "✅ 域名解析正确"
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    echo "[+] 安装 Docker"
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker --now
  fi

  if ! command -v docker-compose &>/dev/null; then
    echo "[+] 安装 docker-compose"
    curl -L https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-$(uname -s)-$(uname -m) \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

# ========== 部署 ==========
deploy() {
  read -rp "绑定域名 (如 tv.example.com): " DOMAIN
  read -rp "证书邮箱: " EMAIL
  read -rp "管理员账号: " ADMIN_USER
  read -rp "管理员密码: " ADMIN_PASS

  check_domain "$DOMAIN" || return

  install_docker

  mkdir -p "$BASE_DIR"
  docker network inspect "$NETWORK" &>/dev/null || docker network create "$NETWORK"

  cat >"$CADDY_FILE" <<EOF
$DOMAIN {
  encode gzip
  reverse_proxy decotv:3000
  tls $EMAIL
}
EOF

  cat >"$COMPOSE_FILE" <<EOF
version: "3.9"
services:
  decotv:
    image: ghcr.io/decohererk/decotv:latest
    restart: unless-stopped
    container_name: decotv
    environment:
      - USERNAME=$ADMIN_USER
      - PASSWORD=$ADMIN_PASS
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://kvrocks:6666
    networks:
      - $NETWORK

  kvrocks:
    image: apache/kvrocks
    restart: unless-stopped
    container_name: kvrocks
    volumes:
      - kvrocks-data:/var/lib/kvrocks
    networks:
      - $NETWORK

  caddy:
    image: caddy:2
    restart: unless-stopped
    container_name: decotv-caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - $NETWORK

volumes:
  kvrocks-data:
  caddy-data:
  caddy-config:

networks:
  $NETWORK:
    external: true
EOF

  cd "$BASE_DIR"
  docker-compose up -d

  echo "🎉 部署完成：https://$DOMAIN"
}

# ========== 更新 ==========
update_app() {
  cd "$BASE_DIR"
  docker-compose pull
  docker-compose up -d
  echo "✅ 镜像已更新"
}

# ========== 卸载 ==========
uninstall_app() {
  read -rp "⚠️ 确认卸载（yes/no）: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && return

  docker-compose down -v || true
  docker network rm "$NETWORK" || true
  rm -rf "$BASE_DIR"
  echo "🗑️ 已完全卸载"
}

# ========== 快捷指令 ==========
install_cli() {
  cp "$0" /usr/local/bin/decotv
  chmod +x /usr/local/bin/decotv
  echo "✅ 快捷命令已创建：decotv"
}

# ========== 菜单 ==========
while true; do
  clear
  echo "========== $APP_NAME 管理面板 =========="
  echo "1️⃣  一键部署"
  echo "2️⃣  更新镜像"
  echo "3️⃣  停止服务"
  echo "4️⃣  启动服务"
  echo "5️⃣  卸载"
  echo "6️⃣  创建快捷指令"
  echo "0️⃣  退出"
  echo "======================================="
  read -rp "请选择: " CHOICE

  case "$CHOICE" in
    1) deploy; pause ;;
    2) update_app; pause ;;
    3) docker-compose -f "$COMPOSE_FILE" down; pause ;;
    4) docker-compose -f "$COMPOSE_FILE" up -d; pause ;;
    5) uninstall_app; pause ;;
    6) install_cli; pause ;;
    0) exit 0 ;;
    *) echo "无效选择"; pause ;;
  esac
done
