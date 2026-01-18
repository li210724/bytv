#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ===========================
# DecoTV One-Click Deploy
# - Docker + (Optional) Nginx reverse proxy
# - Non-invasive, avoid conflicts
# ===========================

APP_NAME="decotv"
APP_DIR="/opt/decotv"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_FILE="${NGINX_CONF_DIR}/decotv.conf"

IMAGE_CORE="ghcr.io/decohererk/decotv:latest"   # from upstream README examples
IMAGE_KVROCKS="apache/kvrocks:latest"

DEFAULT_APP_PORT="3000"     # container exposed port
DEFAULT_HOST_PORT="3000"    # host port (can change)
DEFAULT_PROXY_HTTP_PORT="80"
FALLBACK_PROXY_HTTP_PORT="8080"

# --------- utils ----------
log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[-]\033[0m %s\n" "$*"; }
die()  { err "$*"; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请使用 root 运行：sudo -i 或 sudo bash $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  # set OS_ID, OS_LIKE
  OS_ID=""
  OS_LIKE=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
  echo "${OS_ID}|${OS_LIKE}"
}

is_port_in_use() {
  local p="$1"
  if cmd_exists ss; then
    ss -lntp 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"
    return $?
  elif cmd_exists netstat; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"
    return $?
  else
    # fallback: try bind check via bash /dev/tcp (not perfect)
    (echo >/dev/tcp/127.0.0.1/"${p}") >/dev/null 2>&1 && return 0 || return 1
  fi
}

get_public_ip() {
  local ip=""
  for u in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"
  do
    ip="$(curl -fsSL --max-time 5 "$u" 2>/dev/null || true)"
    ip="${ip//$'\n'/}"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"; return 0
    fi
  done
  echo "YOUR_SERVER_IP"
}

install_pkg() {
  # install packages by best effort
  local pkgs=("$@")
  local os; os="$(detect_os)"
  local id="${os%%|*}"
  local like="${os#*|}"

  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif cmd_exists dnf; then
    dnf install -y "${pkgs[@]}"
  elif cmd_exists yum; then
    yum install -y "${pkgs[@]}"
  elif cmd_exists apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    die "无法识别包管理器，无法自动安装依赖：${pkgs[*]}"
  fi
}

ensure_base_deps() {
  log "检测基础依赖..."
  local missing=()

  cmd_exists curl || missing+=("curl")
  cmd_exists openssl || missing+=("openssl")
  cmd_exists sed || missing+=("sed")
  cmd_exists awk || missing+=("awk")
  cmd_exists grep || missing+=("grep")

  # ss preferred
  if ! cmd_exists ss && ! cmd_exists netstat; then
    # ss usually in iproute2, netstat in net-tools
    missing+=("iproute2")
  fi

  if ((${#missing[@]} > 0)); then
    warn "缺少依赖：${missing[*]}，开始安装..."
    install_pkg "${missing[@]}"
  else
    log "基础依赖齐全"
  fi
}

ensure_docker() {
  log "检测 Docker..."
  if cmd_exists docker; then
    log "Docker 已存在：$(docker --version 2>/dev/null || true)"
  else
    warn "未检测到 Docker，开始安装 Docker（官方脚本方式）..."
    ensure_base_deps
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker >/dev/null 2>&1 || true
    log "Docker 安装完成：$(docker --version 2>/dev/null || true)"
  fi

  if ! systemctl is-active --quiet docker 2>/dev/null; then
    warn "Docker 服务未处于 active，尝试启动..."
    systemctl start docker || true
  fi

  docker info >/dev/null 2>&1 || die "Docker 无法正常工作，请检查 docker 服务状态。"
}

ensure_compose() {
  log "检测 Docker Compose..."
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose 可用：$(docker compose version 2>/dev/null | head -n1)"
    return 0
  fi

  # try docker-compose legacy
  if cmd_exists docker-compose; then
    log "docker-compose 可用：$(docker-compose --version 2>/dev/null || true)"
    return 0
  fi

  warn "未检测到 compose 插件/命令，尝试安装 docker-compose-plugin..."
  if cmd_exists apt-get; then
    install_pkg docker-compose-plugin
  elif cmd_exists dnf; then
    install_pkg docker-compose-plugin
  elif cmd_exists yum; then
    install_pkg docker-compose-plugin
  elif cmd_exists apk; then
    # alpine: docker-cli-compose exists sometimes
    install_pkg docker-cli-compose || true
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose 安装失败，请手动安装 compose 插件后重试。"
}

compose_up() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" up -d)
  else
    (cd "$APP_DIR" && docker-compose -f "$COMPOSE_FILE" up -d)
  fi
}

compose_down() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    if docker compose version >/dev/null 2>&1; then
      (cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" down)
    else
      (cd "$APP_DIR" && docker-compose -f "$COMPOSE_FILE" down)
    fi
  fi
}

compose_pull() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" pull)
  else
    (cd "$APP_DIR" && docker-compose -f "$COMPOSE_FILE" pull)
  fi
}

write_compose() {
  local host_port="$1"
  mkdir -p "$APP_DIR"
  cat >"$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ${IMAGE_CORE}
    container_name: decotv-core
    restart: on-failure
    ports:
      - '${host_port}:${DEFAULT_APP_PORT}'
    env_file:
      - ./.env
    environment:
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks:
      - decotv-network
    depends_on:
      - decotv-kvrocks

  decotv-kvrocks:
    image: ${IMAGE_KVROCKS}
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks
    networks:
      - decotv-network

networks:
  decotv-network:
    driver: bridge

volumes:
  kvrocks-data:
EOF
}

prompt_nonempty() {
  local prompt="$1"
  local v=""
  while true; do
    read -r -p "$prompt" v
    v="${v//[$'\t\r\n ']/}"
    if [[ -n "$v" ]]; then
      echo "$v"; return 0
    fi
    warn "不能为空，请重试。"
  done
}

prompt_password_confirm() {
  local p1 p2
  while true; do
    read -r -s -p "请输入管理员密码: " p1; echo
    read -r -s -p "请再次输入管理员密码: " p2; echo
    if [[ -z "$p1" ]]; then
      warn "密码不能为空。"
      continue
    fi
    if [[ "$p1" != "$p2" ]]; then
      warn "两次密码不一致，请重试。"
      continue
    fi
    echo "$p1"
    return 0
  done
}

write_env() {
  local user="$1"
  local pass="$2"
  local base_url="$3"
  cat >"$ENV_FILE" <<EOF
# DecoTV env
USERNAME=${user}
PASSWORD=${pass}
SITE_BASE=${base_url}
EOF
  chmod 600 "$ENV_FILE"
}

ensure_nginx() {
  if cmd_exists nginx; then
    log "Nginx 已存在：$(nginx -v 2>&1 || true)"
  else
    warn "未检测到 Nginx，将安装（仅用于本项目反代，不覆盖其他站点）..."
    install_pkg nginx
  fi

  mkdir -p "$NGINX_CONF_DIR"
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

write_nginx_conf() {
  local domain="$1"
  local proxy_port="$2"
  local upstream_port="$3"

  cat >"$NGINX_CONF_FILE" <<EOF
# ${APP_NAME} reverse proxy (non-invasive)
# Generated by DecoTV one-click script

server {
  listen ${proxy_port};
  listen [::]:${proxy_port};

  server_name ${domain};

  client_max_body_size 64m;

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF

  nginx -t || die "Nginx 配置测试失败，请检查：${NGINX_CONF_FILE}"
  systemctl reload nginx || systemctl restart nginx
}

show_access() {
  local user="$1"
  local pass="$2"
  local host_port="$3"
  local domain="$4"
  local proxy_port="$5"

  local ip; ip="$(get_public_ip)"

  echo
  echo "=============================="
  echo " DecoTV 部署完成"
  echo "=============================="
  echo "管理员账号: ${user}"
  echo "管理员密码: ${pass}"
  echo "应用端口  : ${host_port}"
  echo

  if [[ -n "$domain" ]]; then
    echo "访问地址(域名): http://${domain}:${proxy_port}"
    if [[ "$proxy_port" == "80" ]]; then
      echo "访问地址(域名): http://${domain}"
    fi
  else
    echo "访问地址(IP):   http://${ip}:${host_port}"
  fi
  echo "安装目录: ${APP_DIR}"
  echo
}

install_flow() {
  ensure_base_deps
  ensure_docker
  ensure_compose

  mkdir -p "$APP_DIR"

  local host_port="${DEFAULT_HOST_PORT}"
  read -r -p "请输入 DecoTV 对外端口(默认 ${DEFAULT_HOST_PORT}): " host_port
  host_port="${host_port:-$DEFAULT_HOST_PORT}"

  if ! [[ "$host_port" =~ ^[0-9]+$ ]] || ((host_port<1 || host_port>65535)); then
    die "端口不合法：$host_port"
  fi

  if is_port_in_use "$host_port"; then
    die "端口 ${host_port} 已被占用，请换一个端口后重试。"
  fi

  local admin_user
  admin_user="$(prompt_nonempty "请输入管理员用户名: ")"

  local admin_pass
  admin_pass="$(prompt_password_confirm)"

  local domain=""
  read -r -p "如需启用 Nginx 反代，请输入绑定域名(留空则不启用反代): " domain
  domain="${domain//[$'\t\r\n ']/}"

  write_compose "$host_port"

  local base_url=""
  if [[ -n "$domain" ]]; then
    # base_url depends on proxy port result; fill later
    base_url="http://${domain}"
  else
    base_url=""
  fi
  write_env "$admin_user" "$admin_pass" "$base_url"

  log "启动容器..."
  compose_up
  log "容器已启动"

  local proxy_port=""
  if [[ -n "$domain" ]]; then
    ensure_nginx

    proxy_port="$DEFAULT_PROXY_HTTP_PORT"
    if is_port_in_use "$DEFAULT_PROXY_HTTP_PORT"; then
      warn "检测到 80 端口已被占用（可能是其他面板/服务），为避免冲突，本项目反代改用 ${FALLBACK_PROXY_HTTP_PORT}。"
      proxy_port="$FALLBACK_PROXY_HTTP_PORT"
      if is_port_in_use "$proxy_port"; then
        warn "端口 ${proxy_port} 也被占用，将跳过反代配置，仅保留 Docker 端口访问。"
        domain=""
        proxy_port=""
      fi
    fi

    if [[ -n "$domain" && -n "$proxy_port" ]]; then
      write_nginx_conf "$domain" "$proxy_port" "$host_port"
      # update SITE_BASE now
      sed -i "s#^SITE_BASE=.*#SITE_BASE=http://${domain}:${proxy_port}#g" "$ENV_FILE" || true
      if [[ "$proxy_port" == "80" ]]; then
        sed -i "s#^SITE_BASE=.*#SITE_BASE=http://${domain}#g" "$ENV_FILE" || true
      fi
      # apply env change
      compose_up
      log "Nginx 反代已生效：${NGINX_CONF_FILE}"
    fi
  fi

  show_access "$admin_user" "$admin_pass" "$host_port" "$domain" "${proxy_port:-$DEFAULT_HOST_PORT}"
}

update_image_flow() {
  [[ -d "$APP_DIR" && -f "$COMPOSE_FILE" ]] || die "未检测到安装目录：${APP_DIR}，请先安装。"
  ensure_docker
  ensure_compose
  log "拉取最新镜像并重建容器..."
  compose_pull
  compose_up
  log "更新完成（已拉取 latest 并重建）"
}

status_flow() {
  ensure_docker
  echo
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | sed -n '1p;/decotv/p' || true
  echo
  if [[ -f "$NGINX_CONF_FILE" ]]; then
    log "检测到 Nginx 配置：${NGINX_CONF_FILE}"
  fi
  echo
}

uninstall_flow() {
  warn "将停止并移除本项目容器，但不会删除你的 Docker，也不会动其他服务。"
  read -r -p "确认卸载 DecoTV？(y/N): " yn
  yn="${yn:-N}"
  if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
    log "已取消"
    return 0
  fi

  compose_down || true

  if [[ -f "$NGINX_CONF_FILE" ]]; then
    rm -f "$NGINX_CONF_FILE"
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx || true) || true
    log "已移除 Nginx 本项目配置：${NGINX_CONF_FILE}"
  fi

  rm -rf "$APP_DIR"
  log "已卸载完成：${APP_DIR}"
}

menu() {
  cat <<'EOF'
==============================
 DecoTV · One-Click Deploy
==============================
1) 安装 / 重装（含依赖检测、可选反代）
2) 更新镜像（pull latest + 重建容器）
3) 状态查看
4) 卸载（仅移除本项目）
0) 退出
EOF
  read -r -p "请选择: " choice
  case "${choice:-}" in
    1) install_flow ;;
    2) update_image_flow ;;
    3) status_flow ;;
    4) uninstall_flow ;;
    0) exit 0 ;;
    *) warn "无效选择";;
  esac
}

main() {
  need_root
  menu
}

main "$@"
