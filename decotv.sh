#!/usr/bin/env bash
set -e

APP="DecoTV"
BASE="/opt/decotv"

ENVF="$BASE/.env"
YML="$BASE/docker-compose.yml"

CORE="decotv-core"
KV="decotv-kvrocks"
NGX="decotv-nginx"
NET="kejilion_net"

SCRIPT_URL="https://github.com/li210724/bytv/main/decotv.sh"

need_root(){ [[ $EUID -eq 0 ]] || { echo "请使用 root"; exit 1; }; }
pause(){ read -r -p "按回车继续..." _; }
has(){ command -v "$1" >/dev/null 2>&1; }

kv(){ grep "^$1=" "$ENVF" 2>/dev/null | cut -d= -f2-; }

docker_ready(){
  has docker || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker network create "$NET" >/dev/null 2>&1 || true
}

compose(){ (cd "$BASE" && docker compose --env-file "$ENVF" "$@"); }

c_state(){
  docker inspect "$1" >/dev/null 2>&1 || { echo "none"; return; }
  docker inspect -f '{{.State.Status}}' "$1"
}

rp_domain(){
  grep server_name "$BASE/nginx/nginx.conf" 2>/dev/null | awk '{print $2}' | tr -d ';'
}

https_alive(){
  [[ "$(c_state "$NGX")" == "running" ]] || return 1
  local d; d="$(rp_domain)"
  [[ -n "$d" ]] || return 1
  curl -k -m 5 "https://$d" >/dev/null 2>&1
}

access_url(){
  if https_alive; then
    echo "https://$(rp_domain)"
  else
    echo "http://$(curl -fsSL https://api.ipify.org):$(kv APP_PORT)"
  fi
}

deploy(){
  docker_ready
  mkdir -p "$BASE"

  read -r -p "用户名 [admin]：" u; u=${u:-admin}
  read -r -p "密码：" p
  read -r -p "访问端口 [3000]：" port; port=${port:-3000}

  cat >"$ENVF" <<EOF
USERNAME=$u
PASSWORD=$p
APP_PORT=$port
SCRIPT_URL=$SCRIPT_URL
EOF

  cat >"$YML" <<EOF
services:
  $CORE:
    image: ghcr.io/decohererk/decotv:latest
    container_name: $CORE
    restart: unless-stopped
    ports:
      - "\${APP_PORT}:3000"
    environment:
      - USERNAME=\${USERNAME}
      - PASSWORD=\${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://$KV:6666
    networks:
      - $NET

  $KV:
    image: apache/kvrocks:latest
    container_name: $KV
    restart: unless-stopped
    networks:
      - $NET

networks:
  $NET:
    external: true
EOF

  compose up -d
  echo "部署完成"
  echo "访问地址：$(access_url)"
}

bind_domain_proxy(){
  docker_ready
  mkdir -p "$BASE/nginx/certs"

  read -r -p "请输入域名：" domain

  # ===== FIX(KFD)：无条件释放 80/443 =====
  nginx_was_running=0
  if [[ "$(c_state "$NGX")" == "running" ]]; then
    nginx_was_running=1
    docker stop "$NGX" >/dev/null 2>&1
    sleep 1
  fi
  # ======================================

  [[ -x ~/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ~/.acme.sh/acme.sh --issue -d "$domain" --standalone || {
    echo "证书申请失败"
    return
  }

  ~/.acme.sh/acme.sh --installcert -d "$domain" \
    --key-file "$BASE/nginx/certs/key.pem" \
    --fullchain-file "$BASE/nginx/certs/cert.pem"

  cat >"$BASE/nginx/nginx.conf" <<EOF
events {}
http {
  server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
  }
  server {
    listen 443 ssl http2;
    server_name $domain;
    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    location / {
      proxy_pass http://$CORE:3000;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
  }
}
EOF

  docker rm -f "$NGX" >/dev/null 2>&1 || true
  docker run -d \
    --name "$NGX" \
    --restart always \
    --network "$NET" \
    -p 80:80 -p 443:443 \
    -v "$BASE/nginx/nginx.conf:/etc/nginx/nginx.conf" \
    -v "$BASE/nginx/certs:/etc/nginx/certs" \
    nginx:latest

  if https_alive; then
    echo "域名绑定成功"
    echo "访问地址：https://$domain"
  else
    echo "域名绑定失败，已回退"
    echo "访问地址：$(access_url)"
  fi
}

menu(){
  clear
  echo "=============================="
  echo " DecoTV 管理面板"
  echo "=============================="
  echo "当前访问地址：$(access_url)"
  echo
  echo "1) 部署 / 重装"
  echo "2) 域名反代"
  echo "0) 退出"
}

need_root
docker_ready

while :; do
  menu
  read -r -p "请选择：" c
  case "$c" in
    1) deploy; pause ;;
    2) bind_domain_proxy; pause ;;
    0) exit ;;
  esac
done
