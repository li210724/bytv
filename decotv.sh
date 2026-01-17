#!/usr/bin/env bash
set -e

# DecoTV 一键安装 & 管理脚本（官方镜像 ghcr.io/decohererk/decotv）
# 菜单保留、HTTPS 绑定域名、与其他服务共存

BASE_DIR="/opt/decotv"
DATA_DIR="$BASE_DIR/data"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
NGINX_CONF_DIR="/etc/nginx/conf.d/decotv"
ACME_ROOT="/var/www/decotv-acme"
APP_PORT=3000
IMAGE="ghcr.io/decohererk/decotv:latest"

ok(){ echo -e "[OK] $*"; }
info(){ echo -e "[*] $*"; }
warn(){ echo -e "[!] $*"; }
err(){ echo -e "[X] $*"; exit 1; }
pause(){ read -rp "按回车继续..." _; }

gen_pass(){ openssl rand -base64 18 | tr -d '=+/\\'; }

check_deps(){
  info "检测基础依赖（缺失则安装）"
  for p in curl openssl lsb-release gnupg certbot; do
    if ! command -v "$p" >/dev/null 2>&1; then
      info "安装依赖：$p"
      apt-get update -y
      apt-get install -y "$p"
    fi
  done
}

ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    info "安装 Docker"
    curl -fsSL https://get.docker.com | sh
  else
    ok "Docker 已存在"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    info "安装 Docker Compose 插件"
    apt-get install -y docker-compose-plugin
  else
    ok "Docker Compose 可用"
  fi
}

ensure_nginx(){
  if ! command -v nginx >/dev/null 2>&1; then
    info "安装 Nginx"
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
  else
    ok "检测到已有 Nginx（仅写配置）"
  fi
}

write_compose(){
  mkdir -p "$BASE_DIR" "$DATA_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ${IMAGE}
    container_name: decotv-core
    restart: unless-stopped
    ports:
      - "127.0.0.1:${APP_PORT}:3000"
    environment:
      - USERNAME=${ADMIN_USER}
      - PASSWORD=${ADMIN_PASS}
    volumes:
      - ${DATA_DIR}:/data
EOF
}

write_nginx_http(){
  mkdir -p "$NGINX_CONF_DIR" "$ACME_ROOT"
  cat > "$NGINX_CONF_DIR/${DOMAIN}.conf" <<EOF
server {
  listen 80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ {
    root ${ACME_ROOT};
  }

  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
}

issue_cert(){
  certbot certonly --webroot -w "${ACME_ROOT}" -d "${DOMAIN}" \
    --agree-tos --non-interactive ${EMAIL:+--email $EMAIL}
}

write_nginx_https(){
  cat > "$NGINX_CONF_DIR/${DOMAIN}-ssl.conf" <<EOF
server {
  listen 443 ssl;
  server_name ${DOMAIN};

  ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
}

install_decotv(){
  check_deps
  ensure_docker
  ensure_nginx

  read -rp "绑定域名（如 tv.example.com）: " DOMAIN
  [[ -z "$DOMAIN" ]] && err "域名不能为空"

  read -rp "证书邮箱（可留空）: " EMAIL

  read -rp "后台用户名（默认 admin）: " ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}

  read -rsp "后台密码（留空自动生成）: " ADMIN_PASS
  echo
  [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(gen_pass)"

  write_compose
  docker compose -f "$COMPOSE_FILE" up -d

  write_nginx_http
  issue_cert
  write_nginx_https

  ln -sf "$BASE_DIR/decotv.sh" /usr/bin/decotv
  chmod +x "$BASE_DIR/decotv.sh"

  systemctl reload nginx || true

  echo
  echo "=============================="
  echo "DecoTV 安装完成"
  echo "访问：https://${DOMAIN}"
  echo "后台用户：$ADMIN_USER"
  echo "后台密码：$ADMIN_PASS"
  echo "=============================="
}

status(){ docker ps | grep decotv-core || echo "未运行"; }
start(){ docker start decotv-core; }
stop(){ docker stop decotv-core; }
restart(){ docker restart decotv-core; }
logs(){ docker logs -f decotv-core; }
update(){ docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d; }

uninstall(){
  docker rm -f decotv-core 2>/dev/null || true
  rm -rf "$BASE_DIR" "$NGINX_CONF_DIR"
  rm -f /usr/bin/decotv
  systemctl reload nginx || true
  ok "已彻底卸载 DecoTV（不影响其他服务）"
}

# Menu
while true; do
  clear
  cat <<EOF
DecoTV 快捷启动面板（官方版 ghcr.io/decohererk/decotv）

1) 安装/重装 DecoTV
2) 查看运行状态
3) 启动
4) 停止
5) 重启
6) 查看日志
7) 更新镜像并重启
8) 显示当前配置
14) 彻底卸载（含配置/数据）
0) 退出
EOF
  read -rp "请选择: " choice
  case "$choice" in
    1) install_decotv ;;
    2) status; pause ;;
    3) start; pause ;;
    4) stop; pause ;;
    5) restart; pause ;;
    6) logs ;;
    7) update; pause ;;
    8) cat "$COMPOSE_FILE"; pause ;;
    14) uninstall; pause ;;
    0) exit 0 ;;
    *) warn "无效选择"; pause ;;
  esac
done
