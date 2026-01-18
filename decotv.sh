#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP="decotv"
STACK_DIR="/opt/decotv"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="$STACK_DIR/.env"

NGX_DIR="/etc/nginx/${APP}"
NGX_BACKUP_DIR="${NGX_DIR}/backup"
CHAIN_NAME="DECO_${APP^^}"

# ========= UI =========
color(){ printf "\033[%sm%s\033[0m" "$1" "$2"; }
green(){ color 32 "$1"; }
yellow(){ color 33 "$1"; }
red(){ color 31 "$1"; }
blue(){ color 36 "$1"; }
hr(){ echo "----------------------------------------"; }
pause(){ read -rp "回车继续..." _; }

is_root(){ [[ "$(id -u)" -eq 0 ]]; }
cmd(){ command -v "$1" >/dev/null 2>&1; }

# ========= Package =========
pkg_mgr(){
  if cmd apt-get; then echo apt
  elif cmd dnf; then echo dnf
  elif cmd yum; then echo yum
  elif cmd apk; then echo apk
  else echo unknown; fi
}

pkg_install(){
  case "$(pkg_mgr)" in
    apt) apt-get update -y && apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) red "不支持的系统"; exit 1 ;;
  esac
}

ensure_deps(){
  local need=()
  for x in curl nginx docker iptables sed grep awk; do
    cmd "$x" || need+=("$x")
  done
  (( ${#need[@]} )) && pkg_install "${need[@]}"
}

# ========= Docker =========
docker_ok(){ cmd docker && docker info >/dev/null 2>&1; }
compose(){ docker compose 2>/dev/null || docker-compose; }

# ========= Nginx =========
nginx_ok(){ cmd nginx; }

nginx_reload(){
  nginx -t && systemctl reload nginx 2>/dev/null || nginx -s reload
}

nginx_include_dirs(){
  nginx -T 2>/dev/null | grep -oE 'include\s+[^;]+' \
  | awk '{print $2}' | sed 's/\*.*//' | uniq
}

nginx_http_reset(){
  curl -sSiv -H "Host: check.local" http://127.0.0.1:80 2>&1 | grep -qi reset
}

nginx_fix_80(){
  hr
  yellow "检测到 Nginx 80 reset，这是域名无法访问的根因"
  read -rp "是否自动修复（安全、可回滚）？[y/N]: " yn
  [[ $yn =~ ^[Yy]$ ]] || return

  local ts="$NGX_BACKUP_DIR/$(date +%F_%H%M%S)"
  mkdir -p "$ts"

  local files
  files=$(grep -RIl 'return\s\+444' /etc/nginx || true)

  if [[ -z "$files" ]]; then
    red "未找到 return 444，可能是更复杂的安全模板"
    return
  fi

  for f in $files; do
    mkdir -p "$ts$(dirname "$f")"
    cp "$f" "$ts$f"
    sed -i 's/return\s\+444/return 404/g' "$f"
  done

  nginx_reload
  green "修复完成，备份在 $ts"
}

write_nginx_site(){
  local domain="$1" port="$2"
  mkdir -p "$NGX_DIR"

  local conf="$NGX_DIR/${APP}_${domain}.conf"
  cat >"$conf"<<EOF
server {
  listen 80;
  server_name $domain;
  location / {
    proxy_pass http://127.0.0.1:$port;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF

  for d in $(nginx_include_dirs); do
    mkdir -p "$d"
    cp "$conf" "$d/"
  done

  nginx_reload
}

# ========= Compose =========
write_compose(){
  mkdir -p "$STACK_DIR"
  cat >"$ENV_FILE"<<EOF
HOST_PORT=$1
USERNAME=$2
PASSWORD=$3
DOMAIN=$4
EOF

  cat >"$COMPOSE_FILE"<<'EOF'
services:
  decotv:
    image: ghcr.io/decohererk/decotv:latest
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:3000"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
EOF
}

# ========= Actions =========
install(){
  ensure_deps
  docker_ok || pkg_install docker
  compose >/dev/null || pkg_install docker-compose

  read -rp "端口(默认3000): " port; port=${port:-3000}
  read -rp "用户名(默认admin): " user; user=${user:-admin}

  while true; do
    read -rp "密码(可见): " p1
    read -rp "再次输入密码: " p2
    [[ "$p1" == "$p2" && -n "$p1" ]] && break
    yellow "密码不一致"
  done

  read -rp "绑定域名(可选): " domain

  write_compose "$port" "$user" "$p1" "$domain"
  (cd "$STACK_DIR" && compose up -d)

  if [[ -n "$domain" ]]; then
    nginx_http_reset && nginx_fix_80
    write_nginx_site "$domain" "$port"
    green "域名访问：http://$domain"
  fi

  green "安装完成"
  pause
}

menu(){
  while true; do
    clear
    echo "DecoTV 管理脚本"
    hr
    echo "1. 安装"
    echo "2. 卸载"
    echo "3. 修复 Nginx 80 reset"
    echo "0. 退出"
    hr
    read -rp "选择: " c
    case "$c" in
      1) install ;;
      3) nginx_fix_80 ;;
      0) exit ;;
    esac
  done
}

is_root || { red "请用 root 运行"; exit 1; }
menu
