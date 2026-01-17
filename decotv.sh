#!/usr/bin/env bash
set -e

# ===============================
# DecoTV 快捷启动面板（最终版）
# 安全 / 共存 / 非侵入
# ===============================

BASE_DIR="/opt/decotv"
DATA_DIR="$BASE_DIR/data"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
NGX_CONF_DIR="/etc/nginx/conf.d/decotv"
ACME_ROOT="/var/www/decotv-acme"
APP_PORT=3000

# ---------- 工具 ----------
ok(){ echo -e "[OK] $*"; }
info(){ echo -e "[*] $*"; }
warn(){ echo -e "[!] $*"; }
err(){ echo -e "[X] $*"; exit 1; }
pause(){ read -rp "按回车继续..." _; }

gen_pass(){
  openssl rand -base64 18 | tr -d '=+/\\'
}

# ---------- 依赖 ----------
check_deps(){
  info "检测基础依赖（仅缺失时安装）"
  for p in curl openssl lsb-release gnupg; do
    if ! command -v $p >/dev/null 2>&1; then
      info "安装依赖: $p"
      apt-get update -y
      apt-get install -y $p
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
    info "未检测到 Nginx，安装中"
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
  else
    ok "检测到已有 Nginx（仅写配置，不接管）"
  fi
}

# ---------- Docker ----------
write_compose(){
  mkdir -p "$BASE_DIR" "$DATA_DIR"
  cat > "$COMPOSE_FILE" <<EOF
services:
  decotv:
    image: decohererk/decotv:latest
    container_name: decotv
    restart: unless-stopped
    ports:
      - "127.0.0.1:${APP_PORT}:3000"
    volumes:
      - ${DATA_DIR}:/data
    environment:
      ADMIN_USER: ${ADMIN_USER}
      ADMIN_PASS: ${ADMIN_PASS}
EOF
}

# ---------- Nginx / HTTPS ----------
write_nginx_http(){
  mkdir -p "$NGX_CONF_DIR" "$ACME_ROOT"
  cat > "$NGX_CONF_DIR/${DOMAIN}.conf" <<EOF
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
  certbot certonly \
    --webroot -w "${ACME_ROOT}" \
    -d "${DOMAIN}" \
    --agree-tos --non-interactive \
    ${EMAIL:+-m ${EMAIL}}
}

write_nginx_https(){
  cat > "$NGX_CONF_DIR/${DOMAIN}-ssl.conf" <<EOF
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

# ---------- 安装 ----------
install_decotv(){
  check_deps
  ensure_docker
  ensure_nginx

  read -rp "绑定域名（如 tv.example.com）: " DOMAIN
  [[ -z "$DOMAIN" ]] && err "域名不能为空"

  read -rp "证书通知邮箱（可留空）: " EMAIL

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
  echo "访问地址: https://${DOMAIN}"
  echo "用户名: $ADMIN_USER"
  echo "密码: $ADMIN_PASS"
  echo "=============================="
}

# ---------- 控制 ----------
status(){ docker ps | grep decotv || echo "未运行"; }
start(){ docker start decotv; }
stop(){ docker stop decotv; }
restart(){ docker restart decotv; }
logs(){ docker logs -f decotv; }
update(){ docker compose -f "$COMPOSE_FILE" pull && docker compose -f "$COMPOSE_FILE" up -d; }

uninstall(){
  docker rm -f decotv 2>/dev/null || true
  rm -rf "$BASE_DIR" "$NGX_CONF_DIR"
  rm -f /usr/bin/decotv
  systemctl reload nginx || true
  ok "已彻底卸载（未影响其他站点）"
}

# ---------- 菜单 ----------
while true; do
clear
cat <<EOF
DecoTV 快捷启动面板

1) 安装 / 重装 DecoTV
2) 查看运行状态
3) 启动
4) 停止
5) 重启
6) 查看日志
7) 更新（拉取新镜像并重启）
8) 显示当前配置
14) 彻底卸载（含数据/配置）
0) 退出
EOF
read -rp "请选择: " c
case "$c" in
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
  *) echo "无效选择"; pause ;;
esac
done
