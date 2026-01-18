#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# DecoTV One-Click Deploy (Docker Compose) + Optional Nginx Proxy + HTTPS
#
# Repo: https://github.com/Decohererk/DecoTV
#
# Commands:
#   bash decotv.sh              # install / update config
#   bash decotv.sh status       # show status
#   bash decotv.sh logs         # show logs
#   bash decotv.sh restart      # restart stack
#   bash decotv.sh update       # pull latest image(s) & recreate
#   bash decotv.sh uninstall    # remove stack (optional delete data)
#
# Default install dir:
#   /opt/decotv
#
# Notes:
# - Nginx is OPTIONAL and non-intrusive: only writes one standalone conf file.
# - HTTPS uses acme.sh webroot; only for this domain.
# ==========================================================

APP_NAME="decotv"
APP_DIR="/opt/decotv"
COMPOSE_YML="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
DATA_DIR="${APP_DIR}/data"

IMAGE_CORE_DEFAULT="ghcr.io/decohererk/decotv:latest"
CORE_CONTAINER="decotv-core"
KV_CONTAINER="decotv-kvrocks"
NETWORK="decotv-network"

# Nginx conf (single file, standalone)
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_FILE="" # computed after domain input

log() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[×]\033[0m %s\n" "$*"; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行：sudo -i 之后再执行"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

os_detect() {
  OS_ID="unknown"
  OS_LIKE=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  fi
}

random_str() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

prompt_default() {
  local prompt="$1" default="$2" var
  read -r -p "${prompt} (默认: ${default}): " var || true
  if [[ -z "${var}" ]]; then
    printf "%s" "${default}"
  else
    printf "%s" "${var}"
  fi
}

prompt_yesno_default() {
  local prompt="$1" default="$2" var
  read -r -p "${prompt} [y/N] (默认: ${default}): " var || true
  var="${var:-$default}"
  case "${var}" in
    y|Y|yes|YES) echo "yes" ;;
    *) echo "no" ;;
  esac
}

prompt_secret_default() {
  local prompt="$1" default="$2" var
  read -r -s -p "${prompt} (默认: ${default}): " var || true
  echo
  if [[ -z "${var}" ]]; then
    printf "%s" "${default}"
  else
    printf "%s" "${var}"
  fi
}

print_deps() {
  log "依赖检测（安装过程中仅打印，不强行干预）："
  if have_cmd curl; then log " - curl: OK"; else warn " - curl: MISSING"; fi
  if have_cmd docker; then log " - docker: OK"; else warn " - docker: MISSING"; fi
  if docker compose version >/dev/null 2>&1; then log " - docker compose: OK"; else warn " - docker compose: MISSING"; fi
  if have_cmd nginx; then log " - nginx: OK"; else warn " - nginx: (可选) NOT INSTALLED"; fi
}

install_docker_debian() {
  log "安装 Docker（Debian/Ubuntu 系）"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/"${OS_ID}"/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo \
"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
${codename} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker >/dev/null 2>&1 || true
}

install_docker_rhel() {
  log "安装 Docker（RHEL/CentOS/Alma/Rocky 系）"
  if have_cmd dnf; then
    dnf -y install dnf-plugins-core ca-certificates curl
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    yum -y install yum-utils ca-certificates curl
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
}

ensure_docker() {
  if have_cmd docker && docker info >/dev/null 2>&1; then
    log "Docker 已安装且可用"
    return 0
  fi

  os_detect
  if [[ "${OS_ID}" == "debian" || "${OS_ID}" == "ubuntu" || "${OS_LIKE}" == *"debian"* ]]; then
    install_docker_debian
  elif [[ "${OS_ID}" == "centos" || "${OS_ID}" == "rhel" || "${OS_ID}" == "almalinux" || "${OS_ID}" == "rocky" || "${OS_LIKE}" == *"rhel"* || "${OS_LIKE}" == *"fedora"* ]]; then
    install_docker_rhel
  else
    err "不支持的系统：${OS_ID}. 请先自行安装 Docker 后再运行本脚本。"
    exit 1
  fi

  if ! have_cmd docker || ! docker info >/dev/null 2>&1; then
    err "Docker 安装失败或不可用。"
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose 插件不可用（docker compose）。请检查 docker-compose-plugin 是否安装。"
    exit 1
  fi

  log "Docker 安装完成"
}

install_nginx_debian() {
  log "安装 Nginx（Debian/Ubuntu 系）"
  apt-get update -y
  apt-get install -y nginx
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

install_nginx_rhel() {
  log "安装 Nginx（RHEL/CentOS/Alma/Rocky 系）"
  if have_cmd dnf; then
    dnf -y install nginx
  else
    yum -y install nginx
  fi
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

ensure_nginx_if_needed() {
  local need="$1" # yes/no
  if [[ "${need}" != "yes" ]]; then
    return 0
  fi
  if have_cmd nginx; then
    log "Nginx 已存在：只写入本项目独立配置文件"
    return 0
  fi

  os_detect
  if [[ "${OS_ID}" == "debian" || "${OS_ID}" == "ubuntu" || "${OS_LIKE}" == *"debian"* ]]; then
    install_nginx_debian
  elif [[ "${OS_ID}" == "centos" || "${OS_ID}" == "rhel" || "${OS_ID}" == "almalinux" || "${OS_ID}" == "rocky" || "${OS_LIKE}" == *"rhel"* || "${OS_LIKE}" == *"fedora"* ]]; then
    install_nginx_rhel
  else
    err "系统不支持自动安装 Nginx：${OS_ID}. 请自行安装 nginx 后再启用反代。"
    exit 1
  fi

  if ! have_cmd nginx; then
    err "Nginx 安装失败。"
    exit 1
  fi
}

sanitize_domain() {
  local d="$1"
  d="${d,,}"
  d="${d// /}"
  echo "$d"
}

nginx_domain_conflict_check() {
  local domain="$1"
  # Try to detect existing server_name usage
  if [[ -d /etc/nginx ]]; then
    if grep -R --line-number -E "server_name\s+.*\b${domain}\b" /etc/nginx 2>/dev/null | head -n 1 >/dev/null; then
      warn "检测到已有 nginx 配置可能占用了该域名：${domain}"
      warn "为避免干预现有站点，本脚本将不会覆盖它。你可以换一个域名，或手动合并配置。"
      return 0
    fi
  fi
  return 1
}

nginx_write_http_conf() {
  local domain="$1" upstream_port="$2" webroot="$3"
  cat > "${NGINX_CONF_FILE}" <<EOF
# Generated by ${APP_NAME} installer
# Standalone vhost for ${domain}

server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  # ACME webroot (for this vhost only)
  location ^~ /.well-known/acme-challenge/ {
    root ${webroot};
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_pass http://127.0.0.1:${upstream_port};
  }
}
EOF
}

nginx_write_https_conf() {
  local domain="$1" upstream_port="$2" webroot="$3" cert="$4" key="$5"
  cat > "${NGINX_CONF_FILE}" <<EOF
# Generated by ${APP_NAME} installer
# Standalone vhost for ${domain}

server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root ${webroot};
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${domain};

  ssl_certificate     ${cert};
  ssl_certificate_key ${key};

  # sane defaults
  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  # modern tls
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_pass http://127.0.0.1:${upstream_port};
  }
}
EOF
}

nginx_reload_safe() {
  if ! have_cmd nginx; then
    err "nginx 命令不存在，无法测试/重载"
    return 1
  fi
  if nginx -t >/dev/null 2>&1; then
    # reload, not restart
    systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
    log "Nginx 已重载（reload）"
    return 0
  else
    err "nginx -t 测试失败：未重载。请手动检查 nginx 配置。"
    nginx -t || true
    return 1
  fi
}

ensure_acme_sh() {
  if [[ -x "${HOME}/.acme.sh/acme.sh" ]]; then
    return 0
  fi
  if ! have_cmd curl; then
    err "缺少 curl，无法安装 acme.sh"
    exit 1
  fi
  log "安装 acme.sh（用于 HTTPS 申请证书）"
  curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1
}

acme_issue_webroot() {
  local domain="$1" webroot="$2" email="$3"
  ensure_acme_sh
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  # register email (non-fatal)
  "${HOME}/.acme.sh/acme.sh" --register-account -m "${email}" >/dev/null 2>&1 || true

  log "申请证书（webroot）：${domain}"
  "${HOME}/.acme.sh/acme.sh" --issue -d "${domain}" -w "${webroot}" --keylength ec-256
}

acme_install_cert() {
  local domain="$1" cert_dir="$2"
  mkdir -p "${cert_dir}"
  local cert="${cert_dir}/fullchain.cer"
  local key="${cert_dir}/${domain}.key"
  log "安装证书到：${cert_dir}"
  "${HOME}/.acme.sh/acme.sh" --install-cert -d "${domain}" \
    --ecc \
    --fullchain-file "${cert}" \
    --key-file "${key}" \
    --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true"
  echo "${cert}|${key}"
}

write_compose() {
  local image_core="$1" port_mapping="$2" username="$3" password="$4"

  mkdir -p "${APP_DIR}" "${DATA_DIR}/kvrocks"

  cat > "${ENV_FILE}" <<EOF
# Generated by ${APP_NAME} installer
IMAGE_CORE=${image_core}
PORT_MAPPING=${port_mapping}
USERNAME=${username}
PASSWORD=${password}
EOF

  cat > "${COMPOSE_YML}" <<'EOF'
services:
  decotv-kvrocks:
    image: apache/kvrocks:latest
    container_name: decotv-kvrocks
    restart: unless-stopped
    command: ["kvrocks", "-c", "/etc/kvrocks/kvrocks.conf"]
    volumes:
      - ./data/kvrocks:/var/lib/kvrocks
    networks:
      - decotv-network

  decotv-core:
    image: ${IMAGE_CORE}
    container_name: decotv-core
    restart: unless-stopped
    depends_on:
      - decotv-kvrocks
    ports:
      - "${PORT_MAPPING}"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks:
      - decotv-network

networks:
  decotv-network:
    name: decotv-network
EOF

  log "已写入：${COMPOSE_YML}"
}

compose_up() {
  log "启动 ${APP_NAME}（docker compose up -d）"
  (cd "${APP_DIR}" && docker compose --env-file .env up -d)
}

compose_down() {
  log "停止 ${APP_NAME}（docker compose down）"
  (cd "${APP_DIR}" && docker compose --env-file .env down)
}

compose_pull() {
  log "拉取最新镜像（docker compose pull）"
  (cd "${APP_DIR}" && docker compose --env-file .env pull)
}

show_status() {
  (cd "${APP_DIR}" && docker compose --env-file .env ps) || true
}

show_logs() {
  (cd "${APP_DIR}" && docker compose --env-file .env logs -n 200 --no-color) || true
}

get_ip() {
  local ip=""
  ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "${ip}"
}

print_access() {
  # shellcheck disable=SC1090
  . "${ENV_FILE}"

  local ip
  ip="$(get_ip)"
  if [[ -z "${ip}" ]]; then
    ip="YOUR_SERVER_IP"
  fi

  echo
  log "部署完成 ✅"
  echo "----------------------------------------"
  echo "安装目录： ${APP_DIR}"
  echo "用户名：   ${USERNAME}"
  echo "密码：     ${PASSWORD}"
  echo "----------------------------------------"

  if [[ -n "${DOMAIN:-}" ]]; then
    if [[ "${HTTPS_ENABLED:-no}" == "yes" ]]; then
      echo "访问地址： https://${DOMAIN}"
    else
      echo "访问地址： http://${DOMAIN}"
    fi
  else
    # PORT_MAPPING e.g. 3000:3000 or 127.0.0.1:3000:3000
    local host_port
    host_port="$(echo "${PORT_MAPPING}" | awk -F: '{print $(NF-1)}')"
    echo "访问地址： http://${ip}:${host_port}"
  fi

  echo "----------------------------------------"
  echo
  echo "常用命令："
  echo "  查看状态： bash decotv.sh status"
  echo "  查看日志： bash decotv.sh logs"
  echo "  重启服务： bash decotv.sh restart"
  echo "  更新镜像： bash decotv.sh update"
  echo "  卸载服务： bash decotv.sh uninstall"
  echo
}

setup_nginx_proxy_flow() {
  local domain="$1" upstream_port="$2"

  domain="$(sanitize_domain "${domain}")"
  if [[ -z "${domain}" ]]; then
    err "域名为空，无法配置反代"
    return 1
  fi

  NGINX_CONF_FILE="${NGINX_CONF_DIR}/${APP_NAME}-${domain}.conf"

  # conflict check (best-effort)
  if nginx_domain_conflict_check "${domain}"; then
    # conflict found -> do not proceed
    return 1
  fi

  local https
  https="$(prompt_yesno_default "是否启用 HTTPS（acme.sh + webroot，仅影响本项目域名）？" "N")"

  local webroot="/var/www/${APP_NAME}-acme"
  mkdir -p "${webroot}/.well-known/acme-challenge"

  # Write HTTP-first conf to allow ACME challenge even for HTTPS
  nginx_write_http_conf "${domain}" "${upstream_port}" "${webroot}"
  log "已写入 Nginx 配置：${NGINX_CONF_FILE}"

  nginx_reload_safe || {
    err "Nginx 配置加载失败，已停止 HTTPS 流程。"
    return 1
  }

  if [[ "${https}" == "yes" ]]; then
    local email cert_dir cert_key cert_path key_path pair
    email="$(prompt_default "用于 Let's Encrypt 的邮箱（可随便填，但建议真实）" "admin@${domain}")"
    cert_dir="/etc/${APP_NAME}/certs/${domain}"

    # issue cert (webroot)
    acme_issue_webroot "${domain}" "${webroot}" "${email}"

    pair="$(acme_install_cert "${domain}" "${cert_dir}")"
    cert_path="${pair%%|*}"
    key_path="${pair##*|}"

    # rewrite nginx conf with ssl
    nginx_write_https_conf "${domain}" "${upstream_port}" "${webroot}" "${cert_path}" "${key_path}"
    log "已更新为 HTTPS Nginx 配置：${NGINX_CONF_FILE}"

    nginx_reload_safe || {
      err "HTTPS 配置测试失败：未重载。你可以手动回滚/检查。"
      return 1
    }

    # store state into env for display
    {
      echo "DOMAIN=${domain}"
      echo "HTTPS_ENABLED=yes"
    } >> "${ENV_FILE}"
  else
    {
      echo "DOMAIN=${domain}"
      echo "HTTPS_ENABLED=no"
    } >> "${ENV_FILE}"
  fi

  log "Nginx 反代配置完成：${domain}"
  return 0
}

do_install() {
  need_root
  print_deps
  ensure_docker

  local image_core username password domain use_nginx host_port port_mapping

  image_core="$(prompt_default "请输入镜像标签（建议默认）" "${IMAGE_CORE_DEFAULT}")"

  domain="$(prompt_default "是否配置域名反代？输入域名启用 Nginx；留空则跳过" "")"
  if [[ -n "${domain}" ]]; then
    use_nginx="yes"
  else
    use_nginx="no"
  fi

  if [[ "${use_nginx}" == "yes" ]]; then
    ensure_nginx_if_needed "yes"
    # When using reverse proxy, bind to localhost by default
    host_port="$(prompt_default "请输入本机反代端口（仅本机监听，推荐默认）" "3000")"
    port_mapping="127.0.0.1:${host_port}:3000"
  else
    host_port="$(prompt_default "请输入映射到宿主机的端口（外部访问端口）" "3000")"
    port_mapping="${host_port}:3000"
  fi

  if ! [[ "${host_port}" =~ ^[0-9]+$ ]] || (( host_port < 1 || host_port > 65535 )); then
    err "端口不合法：${host_port}"
    exit 1
  fi

  username="$(prompt_default "设置 DecoTV 登录用户名" "admin")"
  local default_pass
  default_pass="$(random_str)"
  password="$(prompt_secret_default "设置 DecoTV 登录密码（回车使用随机强密码）" "${default_pass}")"

  write_compose "${image_core}" "${port_mapping}" "${username}" "${password}"
  compose_up
  show_status

  if [[ "${use_nginx}" == "yes" ]]; then
    # Setup nginx proxy (http/https)
    setup_nginx_proxy_flow "${domain}" "${host_port}" || warn "Nginx 反代未完成（可能域名冲突或 nginx 配置测试失败）。"
  fi

  print_access
}

do_restart() {
  need_root
  if [[ ! -f "${COMPOSE_YML}" ]]; then
    err "未找到安装目录：${COMPOSE_YML}"
    exit 1
  fi
  compose_down
  compose_up
  show_status
}

do_update() {
  need_root
  if [[ ! -f "${COMPOSE_YML}" ]]; then
    err "未找到安装目录：${COMPOSE_YML}"
    exit 1
  fi
  compose_pull
  compose_up
  show_status
  log "更新完成：镜像已拉取并重建容器"
}

do_uninstall() {
  need_root
  if [[ ! -d "${APP_DIR}" ]]; then
    warn "未安装：${APP_DIR} 不存在"
    exit 0
  fi

  compose_down || true

  local ans
  read -r -p "是否删除数据目录（会清空 kvrocks 数据）？[y/N]: " ans || true
  if [[ "${ans}" == "y" || "${ans}" == "Y" ]]; then
    rm -rf "${APP_DIR}"
    log "已删除：${APP_DIR}"
  else
    log "保留目录：${APP_DIR}"
  fi
  log "卸载完成"
}

main() {
  local cmd="${1:-install}"
  case "${cmd}" in
    install|"")
      do_install
      ;;
    status)
      show_status
      ;;
    logs)
      show_logs
      ;;
    restart)
      do_restart
      ;;
    update)
      do_update
      ;;
    uninstall|remove)
      do_uninstall
      ;;
    *)
      echo "Usage:"
      echo "  bash decotv.sh              # install/update config"
      echo "  bash decotv.sh status"
      echo "  bash decotv.sh logs"
      echo "  bash decotv.sh restart"
      echo "  bash decotv.sh update"
      echo "  bash decotv.sh uninstall"
      exit 1
      ;;
  esac
}

main "$@"
