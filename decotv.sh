#!/usr/bin/env bash
set -euo pipefail

APP="DecoTV v3"
BASE="/opt/decotv"
NET="decotv-net"
COMPOSE="$BASE/docker-compose.yml"
NGINX_CONF="/etc/nginx/conf.d/decotv.conf"

# ---------------- UI ----------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GRN}[OK]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [[ ${EUID:-999} -eq 0 ]] || die "请用 root 运行"; }
pause() { read -rp "按 Enter 继续..."; }

has() { command -v "$1" &>/dev/null; }

# ---------------- OS detect ----------------
OS_FAMILY="" # debian/ubuntu
detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) OS_FAMILY="$ID" ;;
    *) die "仅支持 Debian/Ubuntu（当前：${ID:-unknown}）" ;;
  esac
}

apt_install() {
  # usage: apt_install pkg1 pkg2...
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

# ---------------- Compose wrapper ----------------
dc() {
  # prefer docker compose (plugin), fallback to docker-compose
  if docker compose version &>/dev/null; then
    docker compose "$@"
  elif has docker-compose; then
    docker-compose "$@"
  else
    die "未找到 docker compose / docker-compose"
  fi
}

# ---------------- Port helpers ----------------
is_port_listen() {
  local p="$1"
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|\\[::\\]:)${p}\$"
}

who_listens_80() {
  # prints process info if any
  ss -ltnp 2>/dev/null | awk 'NR>1 && $4 ~ /:80$/ {print $0}' | head -n1 || true
}

pick_free_port() {
  # try common alt ports
  local candidates=("80" "8080" "8880" "10080" "18080")
  for p in "${candidates[@]}"; do
    if ! is_port_listen "$p"; then
      echo "$p"; return 0
    fi
  done
  # fallback random 20000-60000
  while true; do
    p=$(( (RANDOM % 40001) + 20000 ))
    if ! is_port_listen "$p"; then
      echo "$p"; return 0
    fi
  done
}

# ---------------- Dependencies ----------------
install_base() {
  detect_os

  # basics
  warn "检查并安装基础依赖（curl/jq/dig/ss 等）..."
  apt_install ca-certificates curl jq dnsutils iproute2 >/dev/null
  log "基础依赖就绪"

  # docker
  if ! has docker; then
    warn "未检测到 Docker，开始安装（官方脚本）..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
    log "Docker 安装完成"
  else
    log "Docker 已存在"
  fi

  # compose plugin preferred
  if ! docker compose version &>/dev/null; then
    warn "未检测到 docker compose 插件，尝试安装 docker-compose-plugin..."
    # Debian/Ubuntu 官方仓库常可直接装
    if apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      log "docker compose 插件安装完成"
    else
      warn "docker-compose-plugin 安装失败，尝试安装 docker-compose 二进制..."
      if ! has docker-compose; then
        local ver="v2.25.0"
        curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)" \
          -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        log "docker-compose 安装完成（${ver}）"
      else
        log "docker-compose 已存在"
      fi
    fi
  else
    log "docker compose 插件已存在"
  fi
}

# ---------------- Cloudflare DNS ----------------
cf_ip() { curl -fsSL ipv4.icanhazip.com | tr -d '\n'; }

cf_api() {
  # $1 method, $2 path, $3 json(optional)
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

cf_sync() {
  local ip zone_id rid
  ip="$(cf_ip)"
  [[ -n "$ip" ]] || die "获取公网 IPv4 失败"

  zone_id="$(cf_api GET "/zones?name=${CF_ZONE}" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "❌ Cloudflare Zone 不存在或 Token 无权限"

  rid="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${DOMAIN}" | jq -r '.result[0].id // empty')"

  local payload
  payload="$(jq -cn --arg name "$DOMAIN" --arg content "$ip" '{type:"A",name:$name,content:$content,ttl:120,proxied:false}')"

  if [[ -z "$rid" ]]; then
    warn "➕ 创建 DNS A 记录：${DOMAIN} -> ${ip}"
    cf_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
  else
    warn "♻️ 更新 DNS A 记录：${DOMAIN} -> ${ip}"
    cf_api PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" >/dev/null
  fi

  warn "等待 DNS 生效并校验..."
  sleep 4
  local digip
  digip="$(dig +short "$DOMAIN" | tail -n1 | tr -d '\n' || true)"

  if [[ "$digip" != "$ip" ]]; then
    warn "DNS 解析暂未一致（dig=$digip，本机IP=$ip）。这可能是缓存/未传播完成。"
    read -rp "是否继续部署？(y/n): " go
    [[ "${go:-n}" == "y" ]] || die "已取消部署"
  else
    log "✅ Cloudflare 解析校验通过"
  fi
}

# ---------------- Nginx helpers ----------------
ensure_nginx() {
  if has nginx; then
    log "检测到 Nginx 已安装"
    return 0
  fi

  warn "未检测到 Nginx"
  read -rp "是否安装 Nginx 用于反代？（可能占用 80 端口）(y/n): " yn
  [[ "${yn:-n}" == "y" ]] || return 1

  # 如果 80 已被非 nginx 占用，直接拒绝安装（避免侵入）
  if is_port_listen 80; then
    die "80 端口已被占用，且当前未安装 Nginx。为避免冲突，拒绝自动安装。请释放 80 或选择不使用反代。"
  fi

  warn "开始安装 Nginx..."
  apt_install nginx >/dev/null
  systemctl enable --now nginx
  log "Nginx 安装并启动完成"
}

write_nginx_conf() {
  local listen_port="$1"
  cat >"$NGINX_CONF" <<EOF
# $APP - non-intrusive reverse proxy (only this file)
server {
  listen ${listen_port};
  server_name ${DOMAIN};

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  nginx -t >/dev/null || die "Nginx 配置测试失败：$NGINX_CONF"
  systemctl reload nginx
  log "Nginx 反代已应用（listen ${listen_port}）"
}

# ---------------- Input helpers ----------------
read_hidden_or_visible() {
  # $1 prompt, $2 varname, $3 visible(y/n)
  local prompt="$1" varname="$2" vis="${3:-n}" val
  if [[ "$vis" == "y" ]]; then
    read -rp "$prompt" val
  else
    read -srp "$prompt" val; echo
  fi
  printf -v "$varname" '%s' "$val"
}

read_password_twice() {
  local show="$1"
  local p1 p2
  while true; do
    read_hidden_or_visible "管理员密码: " p1 "$show"
    read_hidden_or_visible "再次输入密码: " p2 "$show"
    [[ -n "$p1" ]] || { warn "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { warn "两次密码不一致，请重试"; continue; }
    PASS="$p1"
    break
  done
}

# ---------------- Deploy ----------------
deploy() {
  echo
  read -rp "域名 (tv.example.com): " DOMAIN
  [[ -n "${DOMAIN:-}" ]] || die "域名不能为空"

  read -rp "管理员账号: " USER
  [[ -n "${USER:-}" ]] || die "账号不能为空"

  read -rp "密码输入是否明文显示？(y/n): " SHOWPASS
  SHOWPASS="${SHOWPASS:-n}"
  read_password_twice "$SHOWPASS"

  # Cloudflare optional
  read -rp "启用 Cloudflare 自动解析 A 记录？(y/n): " CF
  CF="${CF:-n}"

  if [[ "$CF" == "y" ]]; then
    read -rp "CF 主域名(Zone，例如 example.com): " CF_ZONE
    [[ -n "${CF_ZONE:-}" ]] || die "CF_ZONE 不能为空"
    # Token 建议隐藏输入
    read_hidden_or_visible "CF API Token（隐藏输入）: " CF_TOKEN "n"
    [[ -n "${CF_TOKEN:-}" ]] || die "CF_TOKEN 不能为空"
    cf_sync
  fi

  install_base

  mkdir -p "$BASE"
  if ! docker network inspect "$NET" &>/dev/null; then
    docker network create "$NET" >/dev/null
    log "创建 Docker 网络：$NET"
  else
    log "Docker 网络已存在：$NET"
  fi

  # write compose (quote env safely via YAML)
  cat >"$COMPOSE" <<EOF
version: "3.9"
services:
  decotv:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-app
    restart: unless-stopped
    environment:
      USERNAME: "${USER}"
      PASSWORD: "${PASS}"
      NEXT_PUBLIC_STORAGE_TYPE: "kvrocks"
      KVROCKS_URL: "redis://decotv-kv:6666"
    ports:
      - "127.0.0.1:3000:3000"
    networks:
      - ${NET}

  kvrocks:
    image: apache/kvrocks
    container_name: decotv-kv
    restart: unless-stopped
    volumes:
      - kv-data:/var/lib/kvrocks
    networks:
      - ${NET}

volumes:
  kv-data:

networks:
  ${NET}:
    external: true
EOF

  warn "拉起容器..."
  dc -f "$COMPOSE" up -d
  log "容器已启动"

  # Reverse proxy option
  read -rp "是否配置 Nginx 反向代理绑定域名？(y/n): " USE_NGX
  USE_NGX="${USE_NGX:-n}"

  local access="http://${DOMAIN}"

  if [[ "$USE_NGX" == "y" ]]; then
    if ensure_nginx; then
      # Decide listen port for nginx site
      local p80info listen_port

      if ! is_port_listen 80; then
        listen_port=80
      else
        p80info="$(who_listens_80)"
        if echo "$p80info" | grep -qi "nginx"; then
          # nginx already owns 80, safe to add a new server block on 80
          listen_port=80
        else
          warn "检测到 80 端口被其它程序占用："
          echo "  $p80info"
          warn "为避免冲突，将为该站点选择一个空闲端口（域名将变为 domain:port 访问）。"
          listen_port="$(pick_free_port)"
          [[ "$listen_port" == "80" ]] && listen_port="$(pick_free_port)"
        fi
      fi

      write_nginx_conf "$listen_port"
      if [[ "$listen_port" != "80" ]]; then
        access="http://${DOMAIN}:${listen_port}"
      fi
    else
      warn "未启用/未安装 Nginx，跳过反代"
      access="http://${DOMAIN}:3000（仅本机回环映射，外部不可直连；建议自行反代）"
    fi
  else
    warn "未配置 Nginx 反代。由于容器仅监听 127.0.0.1:3000，外部无法直接访问。"
    warn "如需外部访问：请启用 Nginx 反代，或自行用现有反代/面板进行域名绑定。"
  fi

  echo
  echo "=============================="
  echo "🎉 部署完成"
  echo "访问地址：${access}"
  echo "管理账号：${USER}"
  echo "管理密码：${PASS}"
  echo "安装目录：${BASE}"
  echo "=============================="
  echo
}

update_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，先执行部署"
  warn "拉取最新镜像..."
  dc -f "$COMPOSE" pull
  dc -f "$COMPOSE" up -d
  log "✅ 更新完成"
}

start_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，先执行部署"
  dc -f "$COMPOSE" up -d
  log "✅ 已启动"
}

stop_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，先执行部署"
  dc -f "$COMPOSE" down
  log "✅ 已停止"
}

uninstall() {
  read -rp "确认卸载 DecoTV？输入 yes 继续: " OK
  [[ "${OK:-}" == "yes" ]] || { warn "已取消"; return; }

  if [[ -f "$COMPOSE" ]]; then
    dc -f "$COMPOSE" down -v || true
  fi

  docker network rm "$NET" 2>/dev/null || true
  rm -rf "$BASE"

  if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
    if has nginx; then
      nginx -t >/dev/null && systemctl reload nginx || true
    fi
  fi

  log "🗑️ 已卸载（未改动其它服务配置）"
}

install_cli() {
  cp -f "$0" /usr/local/bin/decotv
  chmod +x /usr/local/bin/decotv
  log "✅ 已安装快捷命令：decotv"
}

# ---------------- Main ----------------
need_root

while true; do
  clear
  echo "==== ${APP} 管理面板 ===="
  echo "1. 一键部署（共存/零侵入优先）"
  echo "2. 更新镜像"
  echo "3. 启动服务"
  echo "4. 停止服务"
  echo "5. 卸载"
  echo "6. 安装快捷命令（decotv）"
  echo "0. 退出"
  echo
  read -rp "选择: " C
  case "${C:-}" in
    1) deploy; pause ;;
    2) update_app; pause ;;
    3) start_app; pause ;;
    4) stop_app; pause ;;
    5) uninstall; pause ;;
    6) install_cli; pause ;;
    0) exit 0 ;;
    *) warn "无效选择"; pause ;;
  esac
done
