#!/usr/bin/env bash
# DECOTV_SCRIPT_MARK_v1
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ==========================================================
# DecoTV · One-click Manager (FULL VERSION)
# ==========================================================

APP="DecoTV"
DIR="/opt/decotv"
ENVF="$DIR/.env"
YML="$DIR/docker-compose.yml"

C1="decotv-core"
C2="decotv-kvrocks"
IMG1="ghcr.io/decohererk/decotv:latest"
IMG2="apache/kvrocks:latest"

NGX_DIR="$DIR/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_CERTS="$NGX_DIR/certs"
NGX_C="decotv-nginx"
NGX_IMG="nginx:latest"

NET="decotv-network"

# ✅ 面板脚本更新地址（已按你的要求修改）
SCRIPT_URL_DEFAULT="https://github.com/li210724/bytv/main/decotv.sh"

# ---------------- 基础 ----------------
need_root(){ [[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pause(){ read -r -p "按回车继续..." _; }
kv(){ grep "^$1=" "$ENVF" 2>/dev/null | cut -d= -f2-; }

installed(){
  [[ -f "$ENVF" && -f "$YML" ]] && docker inspect "$C1" >/dev/null 2>&1
}

compose(){ (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }

ensure(){
  has docker || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || { echo "Docker compose 不可用"; exit 1; }
}

get_public_ip(){
  curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}'
}

# ---------------- 端口 / nginx ----------------
port_in_use(){
  ss -lnt | awk '{print $4}' | grep -q ":$1$"
}

ports_owned_by_our_nginx(){
  docker ps --format '{{.Names}}' | grep -q "^${NGX_C}$" || return 1
  docker port "$NGX_C" 2>/dev/null | grep -Eq '(:80->|:443->)'
}

stop_our_nginx_if_running(){
  if docker ps --format '{{.Names}}' | grep -q "^${NGX_C}$"; then
    echo "检测到 ${NGX_C} 正在占用端口，临时停止..."
    docker stop "$NGX_C" >/dev/null
    sleep 1
    return 0
  fi
  return 1
}

# ---------------- 安装配置 ----------------
write_cfg(){
  local port="$1" user="$2" pass="$3"
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$user
PASSWORD=$pass
APP_PORT=$port
SCRIPT_URL=$SCRIPT_URL_DEFAULT
EOF

  cat >"$YML" <<EOF
services:
  decotv-core:
    image: $IMG1
    container_name: $C1
    restart: unless-stopped
    ports:
      - "\${APP_PORT}:3000"
    environment:
      - USERNAME=\${USERNAME}
      - PASSWORD=\${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://$C2:6666
    networks: [$NET]
    depends_on: [$C2]

  decotv-kvrocks:
    image: $IMG2
    container_name: $C2
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks
    networks: [$NET]

networks:
  $NET:
    name: $NET
    driver: bridge

volumes:
  kvrocks-data: {}
EOF
}

# ---------------- 部署 ----------------
do_deploy(){
  ensure
  read -r -p "用户名 [admin]：" user; user="${user:-admin}"
  while :; do
    read -r -p "密码：" p1
    read -r -p "确认密码：" p2
    [[ -n "$p1" && "$p1" == "$p2" ]] && break
    echo "密码不一致"
  done
  read -r -p "访问端口 [3000]：" port; port="${port:-3000}"
  write_cfg "$port" "$user" "$p1"
  compose up -d
  echo "部署完成：http://$(get_public_ip):$port"
}

# ---------------- acme + nginx ----------------
ensure_acme(){
  [[ -x ~/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null
}

write_nginx_conf(){
  local domain="$1"
  cat >"$NGX_CONF" <<EOF
events {}
http {
  server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
  }
  server {
    listen 443 ssl;
    server_name $domain;
    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    location / {
      proxy_pass http://$C1:3000;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
  }
}
EOF
}

run_nginx(){
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true
  docker run -d \
    --name "$NGX_C" \
    --restart always \
    --network "$NET" \
    -p 80:80 -p 443:443 \
    -v "$NGX_CONF:/etc/nginx/nginx.conf" \
    -v "$NGX_CERTS:/etc/nginx/certs" \
    "$NGX_IMG" >/dev/null
}

bind_domain_proxy(){
  installed || { echo "请先部署"; return; }

  if port_in_use 80 || port_in_use 443; then
    ports_owned_by_our_nginx && stop_our_nginx_if_running || {
      echo "80/443 被其他服务占用，请释放端口"
      return
    }
  fi

  read -r -p "输入域名：" domain
  ensure_acme

  ~/.acme.sh/acme.sh --issue -d "$domain" --standalone || return
  mkdir -p "$NGX_CERTS"
  ~/.acme.sh/acme.sh --installcert -d "$domain" \
    --key-file "$NGX_CERTS/key.pem" \
    --fullchain-file "$NGX_CERTS/cert.pem"

  write_nginx_conf "$domain"
  run_nginx
  sed -i '/^RP_DOMAIN=/d' "$ENVF"
  echo "RP_DOMAIN=$domain" >>"$ENVF"
  echo "HTTPS 已完成：https://$domain"
}

# ---------------- 更新 / 卸载 ----------------
update_images(){
  compose pull
  compose up -d
}

update_script_self(){
  local url path tmp
  url="$(kv SCRIPT_URL)"
  path="$(readlink -f "$0")"
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  grep -q "DECOTV_SCRIPT_MARK_v1" "$tmp" || { echo "校验失败"; return; }
  cp "$tmp" "$path"
  chmod +x "$path"
  echo "脚本已更新"
}

do_uninstall(){
  compose down -v || true
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true
  rm -rf "$DIR"
  echo "已卸载"
}

# ---------------- UI ----------------
menu(){
  clear
  echo "DECOTV_SCRIPT_MARK_v1"
  echo "1) 部署"
  echo "2) 更新镜像"
  echo "3) 域名 HTTPS 反代"
  echo "4) 更新面板脚本"
  echo "5) 卸载"
  echo "0) 退出"
}

main(){
  need_root
  ensure
  while :; do
    menu
    read -r -p "选择：" c
    case "$c" in
      1) do_deploy; pause ;;
      2) update_images; pause ;;
      3) bind_domain_proxy; pause ;;
      4) update_script_self; pause ;;
      5) do_uninstall; exit ;;
      0) exit ;;
    esac
  done
}

main
