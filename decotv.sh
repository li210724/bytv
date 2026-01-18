#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# DecoTV One-Click Deploy (Stable)
# - Docker Compose
# - Optional Nginx reverse proxy (HTTP / HTTPS via acme.sh webroot)
# - Safe under set -euo pipefail (no silent exit)
#
# Commands:
#   ./decotv.sh              # install / configure
#   ./decotv.sh status       # show status
#   ./decotv.sh logs         # last 200 logs
#   ./decotv.sh restart      # restart stack
#   ./decotv.sh update       # pull latest images & recreate
#   ./decotv.sh uninstall   # stop & remove (optionally delete data)
# ==========================================================

APP_NAME="decotv"
APP_DIR="/opt/decotv"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
DATA_DIR="${APP_DIR}/data"

IMAGE_CORE_DEFAULT="ghcr.io/decohererk/decotv:latest"
IMAGE_KV="apache/kvrocks:latest"

NGINX_CONF_DIR="/etc/nginx/conf.d"

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; exit 1; }

need_root(){ [[ $EUID -eq 0 ]] || err "请使用 root 运行"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# --- Safe random (pipefail-safe) ---
random_str(){
  local s
  s="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  [[ -n "$s" ]] || s="$(date +%s%N | sha256sum | awk '{print $1}' | head -c 24)"
  printf '%s' "$s"
}

prompt(){ local m="$1" d="$2" v; read -r -p "$m (默认: $d): " v || true; echo "${v:-$d}"; }
prompt_secret(){ local m="$1" d="$2" v; read -r -s -p "$m (默认随机): " v || true; echo; echo "${v:-$d}"; }
prompt_yn(){ local m="$1" d="${2:-N}" v; read -r -p "$m [y/N] (默认:$d): " v || true; v="${v:-$d}"; [[ "$v" =~ ^[yY] ]] && echo yes || echo no; }

os_detect(){ OS_ID=unknown; OS_LIKE=""; [[ -r /etc/os-release ]] && . /etc/os-release && OS_ID="${ID:-unknown}" && OS_LIKE="${ID_LIKE:-}"; }

ensure_docker(){
  if have docker && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker & docker compose 可用"; return
  fi
  os_detect
  log "安装 Docker"
  if [[ "$OS_ID" == debian || "$OS_ID" == ubuntu || "$OS_LIKE" == *debian* ]]; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    [[ -f /etc/apt/keyrings/docker.gpg ]] || curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $codename stable" >/etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    err "不支持的系统，请手动安装 Docker"
  fi
  systemctl enable --now docker || true
}

ensure_nginx(){
  if have nginx; then log "Nginx 已存在"; return; fi
  os_detect
  log "安装 Nginx"
  if [[ "$OS_ID" == debian || "$OS_ID" == ubuntu || "$OS_LIKE" == *debian* ]]; then
    apt-get update -y && apt-get install -y nginx
  else
    err "不支持的系统，请手动安装 Nginx"
  fi
  systemctl enable --now nginx || true
}

write_compose(){
  local image="$1" portmap="$2" user="$3" pass="$4"
  mkdir -p "$APP_DIR" "$DATA_DIR/kvrocks"
  cat >"$ENV_FILE"<<EOF
IMAGE_CORE=$image
PORT_MAPPING=$portmap
USERNAME=$user
PASSWORD=$pass
EOF
  cat >"$COMPOSE_FILE"<<'EOF'
services:
  kvrocks:
    image: apache/kvrocks:latest
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes:
      - ./data/kvrocks:/var/lib/kvrocks
    networks: [decotv]

  core:
    image: ${IMAGE_CORE}
    container_name: decotv-core
    restart: unless-stopped
    depends_on: [kvrocks]
    ports:
      - "${PORT_MAPPING}"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://kvrocks:6666
    networks: [decotv]

networks:
  decotv:
    name: decotv-network
EOF
}

dc(){ (cd "$APP_DIR" && docker compose --env-file .env "$@"); }

nginx_conf_http(){
  local d="$1" p="$2" root="$3"
  cat >"$NGINX_CONF_DIR/decotv-$d.conf"<<EOF
server {
  listen 80;
  server_name $d;
  location ^~ /.well-known/acme-challenge/ { root $root; }
  location / {
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass http://127.0.0.1:$p;
  }
}
EOF
}

nginx_conf_https(){
  local d="$1" p="$2" root="$3" crt="$4" key="$5"
  cat >"$NGINX_CONF_DIR/decotv-$d.conf"<<EOF
server {
  listen 80; server_name $d;
  location ^~ /.well-known/acme-challenge/ { root $root; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2; server_name $d;
  ssl_certificate $crt;
  ssl_certificate_key $key;
  ssl_protocols TLSv1.2 TLSv1.3;
  location / {
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_pass http://127.0.0.1:$p;
  }
}
EOF
}

ensure_acme(){
  [[ -x "$HOME/.acme.sh/acme.sh" ]] || curl -fsSL https://get.acme.sh | sh
}

install(){
  need_root
  ensure_docker

  image="$(prompt "镜像" "$IMAGE_CORE_DEFAULT")"
  domain="$(prompt "域名反代（留空跳过）" "")"
  if [[ -n "$domain" ]]; then
    ensure_nginx
    port="$(prompt "本机监听端口(反代)" "3000")"
    portmap="127.0.0.1:$port:3000"
  else
    port="$(prompt "外部访问端口" "3000")"
    portmap="$port:3000"
  fi

  user="$(prompt "登录用户名" "admin")"
  defp="$(random_str)"
  pass="$(prompt_secret "登录密码" "$defp")"

  write_compose "$image" "$portmap" "$user" "$pass"
  dc up -d

  if [[ -n "$domain" ]]; then
    root="/var/www/decotv-acme"
    mkdir -p "$root/.well-known/acme-challenge"
    nginx_conf_http "$domain" "$port" "$root"
    nginx -t && systemctl reload nginx || true

    if [[ "$(prompt_yn "启用 HTTPS?" "N")" == yes ]]; then
      ensure_acme
      email="$(prompt "证书邮箱" "admin@$domain")"
      "$HOME/.acme.sh/acme.sh" --register-account -m "$email" || true
      "$HOME/.acme.sh/acme.sh" --issue -d "$domain" -w "$root" --keylength ec-256
      certdir="/etc/decotv/certs/$domain"; mkdir -p "$certdir"
      "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" --ecc \
        --fullchain-file "$certdir/fullchain.cer" \
        --key-file "$certdir/$domain.key" \
        --reloadcmd "systemctl reload nginx || true"
      nginx_conf_https "$domain" "$port" "$root" "$certdir/fullchain.cer" "$certdir/$domain.key"
      nginx -t && systemctl reload nginx || true
      echo "DOMAIN=$domain" >>"$ENV_FILE"
      echo "HTTPS_ENABLED=yes" >>"$ENV_FILE"
    else
      echo "DOMAIN=$domain" >>"$ENV_FILE"
      echo "HTTPS_ENABLED=no" >>"$ENV_FILE"
    fi
  fi

  ip="$(curl -fsSL https://api.ipify.org || true)"
  echo
  log "完成"
  [[ -n "$domain" ]] && echo "访问: http${HTTPS_ENABLED:+s}://$domain" || echo "访问: http://$ip:$port"
  echo "用户名: $user"
  echo "密码: $pass"
}

case "${1:-install}" in
  install) install;;
  status) dc ps;;
  logs) dc logs -n 200;;
  restart) dc down && dc up -d;;
  update) dc pull && dc up -d;;
  uninstall)
    dc down || true
    read -r -p "删除数据目录? [y/N]: " a
    [[ "$a" =~ ^[yY] ]] && rm -rf "$APP_DIR"
    ;;
  *) echo "Usage: $0 [install|status|logs|restart|update|uninstall]";;
esac
