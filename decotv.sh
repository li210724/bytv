#!/usr/bin/env bash
# DECOTV_SCRIPT_MARK_v1
set -e

APP="DecoTV"
BASE="/opt/decotv"
ENVF="$BASE/.env"
YML="$BASE/docker-compose.yml"

CORE="decotv-core"
KV="decotv-kvrocks"
NGX="decotv-nginx"

NET="decotv-network"
SCRIPT_URL="https://github.com/li210724/bytv/main/decotv.sh"

# ---------------- 工具 ----------------
need_root(){ [[ $EUID -eq 0 ]] || { echo "请使用 root"; exit 1; }; }
pause(){ read -r -p "按回车继续..." _; }
has(){ command -v "$1" >/dev/null 2>&1; }

kv(){ grep "^$1=" "$ENVF" 2>/dev/null | cut -d= -f2-; }

docker_ok(){
  has docker || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
}

compose(){ (cd "$BASE" && docker compose --env-file "$ENVF" "$@"); }

public_ip(){
  curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}'
}

# ---------------- 状态判断（科技 Lion 核心） ----------------
nginx_running(){
  docker inspect "$NGX" >/dev/null 2>&1 \
  && [[ "$(docker inspect -f '{{.State.Running}}' "$NGX")" == "true" ]]
}

https_alive(){
  nginx_running || return 1
  local d
  d="$(grep server_name "$BASE/nginx/nginx.conf" 2>/dev/null | awk '{print $2}' | tr -d ';')"
  curl -k -m 5 "https://$d" >/dev/null 2>&1
}

access_url(){
  if https_alive; then
    local d
    d="$(grep server_name "$BASE/nginx/nginx.conf" | awk '{print $2}' | tr -d ';')"
    echo "https://$d"
  else
    echo "http://$(public_ip):$(kv APP_PORT)"
  fi
}

# ---------------- 部署 ----------------
deploy(){
  docker_ok
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
    networks: [$NET]

  $KV:
    image: apache/kvrocks:latest
    container_name: $KV
    restart: unless-stopped
    networks: [$NET]

networks:
  $NET:
    name: $NET
EOF

  compose up -d
  echo "部署完成"
  echo "访问地址：$(access_url)"
}

# ---------------- 反代域名（严格科技 Lion） ----------------
domain_proxy(){
  mkdir -p "$BASE/nginx/certs"

  # 1. 端口检测
  local stopped=0
  if ss -lnt | grep -Eq ':80 |:443 '; then
    if nginx_running; then
      docker stop "$NGX"
      stopped=1
    else
      echo "80/443 被其他服务占用，无法申请证书"
      return
    fi
  fi

  read -r -p "请输入域名：" domain

  # 2. acme
  [[ -x ~/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --issue -d "$domain" --standalone || {
    echo "证书申请失败"
    return
  }

  ~/.acme.sh/acme.sh --installcert -d "$domain" \
    --key-file "$BASE/nginx/certs/key.pem" \
    --fullchain-file "$BASE/nginx/certs/cert.pem"

  # 3. nginx 配置
  cat >"$BASE/nginx/nginx.conf" <<EOF
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
      proxy_pass http://$CORE:3000;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$remote_addr;
    }
  }
}
EOF

  docker rm -f "$NGX" >/dev/null 2>&1 || true
  docker run -d --name "$NGX" \
    --network "$NET" \
    -p 80:80 -p 443:443 \
    -v "$BASE/nginx/nginx.conf:/etc/nginx/nginx.conf" \
    -v "$BASE/nginx/certs:/etc/nginx/certs" \
    nginx:latest

  # 4. 回滚
  [[ $stopped -eq 1 ]] && docker start "$NGX" >/dev/null

  # 5. 实测访问
  if https_alive; then
    echo "反代成功"
    echo "访问地址：https://$domain"
  else
    echo "反代异常，已回退为 IP 访问"
    echo "访问地址：$(access_url)"
  fi
}

# ---------------- 菜单 ----------------
menu(){
  clear
  echo "DECOTV_SCRIPT_MARK_v1"
  echo "=============================="
  echo " $APP · 管理面板"
  echo "=============================="
  echo "当前访问地址：$(access_url)"
  echo
  echo "1) 部署 / 重装"
  echo "2) 状态"
  echo "3) 日志"
  echo "4) 域名反代（HTTPS）"
  echo "0) 退出"
}

logs(){
  docker logs -f --tail=200 "$CORE"
}

status(){
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo
  echo "访问地址：$(access_url)"
}

# ---------------- 主程序 ----------------
need_root
docker_ok

while :; do
  menu
  read -r -p "请选择：" c
  case "$c" in
    1) deploy; pause ;;
    2) status; pause ;;
    3) logs ;;
    4) domain_proxy; pause ;;
    0) exit ;;
  esac
done
