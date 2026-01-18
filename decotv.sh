#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# =======================
# DecoTV Smart One-Click (容器域名绑定方案 - TechLion风格)
# - 反代用 docker 内置 nginx 容器（decotv-proxy），不依赖系统 nginx
# - 域名绑定通过 docker network：proxy_pass http://decotv-core:3000
# - 可重复执行：down --remove-orphans + 清理旧固定名容器
# - 尽量不冲突：80/443 不可用自动换端口；失败自动降级为直连端口
# - 密码两次确认；安装后明文显示一次
# - 更新镜像：pull latest + 重建
# - 域名解析提示：是否指向本机
# - 服务探测：多路径等待
# - HTTPS(可选)：acme.sh + webroot（推荐用 80/443；不通则自动降级）
# - 关键增强：PASSWORD 注入校验（容器内校验，不通过则自动重建一次）
# =======================

APP_DIR="/opt/decotv"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
PROJECT_NAME="decotv"

# images
IMAGE_CORE="ghcr.io/decohererk/decotv:latest"
IMAGE_KVROCKS="apache/kvrocks:latest"
IMAGE_PROXY="nginx:alpine"

CONTAINER_PORT="3000"

# ports
DEFAULT_HOST_PORT="3000"
HTTP_PORTS=(80 8080 8880 9080 10080)
HTTPS_PORTS=(443 8443 9443 10443)

# proxy files
PROXY_DIR="$APP_DIR/proxy"
PROXY_CONF="$PROXY_DIR/decotv.conf"
PROXY_WEBROOT="$PROXY_DIR/www"   # acme webroot
PROXY_CERTS="$PROXY_DIR/certs"   # mounted certs

log(){  echo "[+] $*"; }
warn(){ echo "[!] $*"; }
err(){  echo "[-] $*" >&2; }
die(){  err "$*"; exit 1; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：sudo -i 或 sudo bash $0"; }
have(){ command -v "$1" >/dev/null 2>&1; }

trim(){
  local s="$*"
  s="${s//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

pm_detect(){
  if have apt-get; then echo apt
  elif have dnf; then echo dnf
  elif have yum; then echo yum
  elif have apk; then echo apk
  else echo unknown
  fi
}

pm_install(){
  local pm; pm="$(pm_detect)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) die "无法识别包管理器，无法自动安装依赖：$*" ;;
  esac
}

ensure_base(){
  log "检测基础依赖..."
  local miss=()
  have curl || miss+=(curl)
  have openssl || miss+=(openssl)
  have awk || miss+=(awk)
  have sed || miss+=(sed)
  have grep || miss+=(grep)
  have ss || miss+=(iproute2)
  if ((${#miss[@]})); then
    warn "安装依赖：${miss[*]}"
    pm_install "${miss[@]}" || true
  fi
}

port_in_use(){
  local p="$1"
  if have ss; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${p}$"
  else
    (echo >/dev/tcp/127.0.0.1/"${p}") >/dev/null 2>&1
  fi
}

pick_free_port(){
  local p
  for p in "$@"; do
    if ! port_in_use "$p"; then
      echo "$p"; return 0
    fi
  done
  echo ""
}

public_ip(){
  local ip=""
  for u in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    ip="$(curl -fsSL --max-time 5 "$u" 2>/dev/null || true)"
    ip="${ip//$'\n'/}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  done
  echo "YOUR_SERVER_IP"
}

prompt_port(){
  local tip="$1" def="$2" v=""
  read -r -p "${tip}(默认 ${def}): " v
  v="$(trim "${v:-$def}")"
  [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1 && v<=65535)) || die "端口不合法：$v"
  echo "$v"
}

prompt_nonempty(){
  local tip="$1" v=""
  while true; do
    read -r -p "$tip" v
    v="$(trim "$v")"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    warn "不能为空，请重试。"
  done
}

prompt_password_confirm(){
  local p1 p2
  while true; do
    read -r -s -p "请输入管理员密码: " p1; echo
    read -r -s -p "请再次输入管理员密码: " p2; echo
    [[ -n "$p1" ]] || { warn "密码不能为空。"; continue; }
    [[ "$p1" == "$p2" ]] || { warn "两次密码不一致，请重试。"; continue; }
    echo "$p1"; return 0
  done
}

domain_dns_hint(){
  local domain="$1"
  local myip; myip="$(public_ip)"
  [[ "$myip" == "YOUR_SERVER_IP" ]] && return 0

  local ips=""
  if have getent; then
    ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ $//')"
  elif have nslookup; then
    ips="$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ $//')"
  fi

  [[ -z "$ips" ]] && { warn "域名解析检查：未能获取 ${domain} 解析记录（不影响安装）"; return 0; }

  if echo " $ips " | grep -q " $myip "; then
    log "域名解析检查：${domain} 已指向本机 IP（${myip}）"
  else
    warn "域名解析检查：${domain} 解析为 [${ips}]，本机 IP 是 [${myip}]"
    warn "如需域名访问，请确认 DNS A/AAAA 指向本机。"
  fi
}

ensure_docker(){
  log "检测 Docker..."
  if have docker; then
    log "Docker 已存在：$(docker --version 2>/dev/null || true)"
  else
    warn "安装 Docker（get.docker.com）..."
    ensure_base
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker 不可用，请检查：systemctl status docker"
}

ensure_compose(){
  log "检测 Docker Compose..."
  if docker compose version >/dev/null 2>&1; then
    log "Compose 可用：$(docker compose version 2>/dev/null | head -n1)"
    return 0
  fi
  if have docker-compose; then
    log "docker-compose 可用：$(docker-compose --version 2>/dev/null || true)"
    return 0
  fi
  warn "安装 compose 插件..."
  pm_install docker-compose-plugin || true
  docker compose version >/dev/null 2>&1 || die "Compose 不可用，请手动安装后重试"
}

compose(){
  if docker compose version >/dev/null 2>&1; then
    (cd "$APP_DIR" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose -f "$COMPOSE_FILE" "$@")
  else
    (cd "$APP_DIR" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker-compose -f "$COMPOSE_FILE" "$@")
  fi
}

write_env(){
  local u="$1" p="$2" base="$3"
  cat >"$ENV_FILE" <<EOF
USERNAME=${u}
PASSWORD=${p}
SITE_BASE=${base}
EOF
  chmod 600 "$ENV_FILE"
}

cleanup_project(){
  mkdir -p "$APP_DIR"
  if [[ -f "$COMPOSE_FILE" ]]; then
    warn "清理本项目残留（down --remove-orphans）..."
    compose down --remove-orphans >/dev/null 2>&1 || true
  fi
  # 防御：旧脚本可能写死 container_name
  for cn in decotv-core decotv-kvrocks decotv-proxy; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$cn"; then
      warn "发现旧固定名容器占用：$cn，自动移除..."
      docker rm -f "$cn" >/dev/null 2>&1 || true
    fi
  done
}

detect_core_container(){
  docker ps --format '{{.Names}}' | grep -E "^${PROJECT_NAME}.*core" | head -n1 || true
}

assert_password_in_container(){
  local core="$1"
  [[ -n "$core" ]] || return 1
  local ok=""
  ok="$(docker exec "$core" sh -lc '[ -n "${PASSWORD:-}" ] && echo OK || echo NO' 2>/dev/null || true)"
  [[ "$ok" == "OK" ]]
}

write_proxy_http_conf(){
  local domain="$1" http_port="$2"
  mkdir -p "$PROXY_DIR" "$PROXY_WEBROOT" "$PROXY_CERTS"
  cat >"$PROXY_CONF" <<EOF
server {
  listen 80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / {
    proxy_pass http://decotv-core:${CONTAINER_PORT};
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
  # 注意：proxy 容器内部永远监听 80；宿主机用映射端口 http_port
  : > /dev/null
}

write_proxy_https_conf(){
  local domain="$1" cert="$2" key="$3"
  mkdir -p "$PROXY_DIR" "$PROXY_WEBROOT" "$PROXY_CERTS"
  cat >"$PROXY_CONF" <<EOF
server {
  listen 80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  server_name ${domain};

  ssl_certificate     /etc/nginx/certs/${domain}.crt;
  ssl_certificate_key /etc/nginx/certs/${domain}.key;

  location / {
    proxy_pass http://decotv-core:${CONTAINER_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF

  cp -f "$cert" "$PROXY_CERTS/${domain}.crt"
  cp -f "$key"  "$PROXY_CERTS/${domain}.key"
}

ensure_acmesh(){
  if [[ -x "${HOME}/.acme.sh/acme.sh" ]] || have acme.sh; then return 0; fi
  warn "安装 acme.sh（仅用于本项目 HTTPS，webroot 非侵入）..."
  curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1 || return 1
  return 0
}

issue_https_webroot(){
  local domain="$1"
  local acme="${HOME}/.acme.sh/acme.sh"
  [[ -x "$acme" ]] || acme="$(command -v acme.sh 2>/dev/null || true)"
  [[ -n "${acme:-}" ]] || return 1
  mkdir -p "$PROXY_WEBROOT/.well-known/acme-challenge"
  "$acme" --issue -d "$domain" --webroot "$PROXY_WEBROOT" --keylength ec-256 >/dev/null 2>&1 \
    || "$acme" --issue -d "$domain" --webroot "$PROXY_WEBROOT" >/dev/null 2>&1 \
    || return 1
  return 0
}

export_https_files(){
  local domain="$1"
  local acme="${HOME}/.acme.sh/acme.sh"
  [[ -x "$acme" ]] || acme="$(command -v acme.sh 2>/dev/null || true)"
  [[ -n "${acme:-}" ]] || return 1

  local outdir="$PROXY_DIR/_acme_out"
  mkdir -p "$outdir"
  local cert="${outdir}/${domain}.crt"
  local key="${outdir}/${domain}.key"

  "$acme" --install-cert -d "$domain" --ecc --key-file "$key" --fullchain-file "$cert" >/dev/null 2>&1 \
    || "$acme" --install-cert -d "$domain" --key-file "$key" --fullchain-file "$cert" >/dev/null 2>&1 \
    || return 1

  echo "${cert}|${key}"
}

wait_ready(){
  local port="$1"
  have curl || return 0
  local base="http://127.0.0.1:${port}"
  local paths=("/" "/login" "/api" "/api/health" "/health" "/healthz")
  local i
  log "服务探测：等待服务可用..."
  for ((i=0;i<20;i++)); do
    local p
    for p in "${paths[@]}"; do
      if curl -fsS --max-time 2 "${base}${p}" >/dev/null 2>&1; then
        log "服务探测：${base}${p} 可访问"
        return 0
      fi
    done
    sleep 1
  done
  warn "服务探测：未在预期时间内确认（不代表失败），你可稍后重试访问"
  return 0
}

write_compose(){
  local host_port="$1"
  local enable_proxy="$2"   # 0/1
  local http_port="$3"      # host http mapped port
  local enable_https="$4"   # 0/1
  local https_port="$5"     # host https mapped port

  mkdir -p "$APP_DIR" "$PROXY_DIR" "$PROXY_WEBROOT" "$PROXY_CERTS"

  if [[ "$enable_proxy" == "1" ]]; then
    # 有域名反代时：core 不强制暴露宿主端口（避免冲突）
    cat >"$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ${IMAGE_CORE}
    restart: on-failure
    env_file: [./.env]
    environment:
      - USERNAME=\${USERNAME}
      - PASSWORD=\${PASSWORD}
      - SITE_BASE=\${SITE_BASE}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    expose: ['${CONTAINER_PORT}']
    networks: [decotv-network]
    depends_on: [decotv-kvrocks]

  decotv-kvrocks:
    image: ${IMAGE_KVROCKS}
    restart: unless-stopped
    volumes: [kvrocks-data:/var/lib/kvrocks]
    networks: [decotv-network]

  decotv-proxy:
    image: ${IMAGE_PROXY}
    restart: unless-stopped
    ports:
      - '${http_port}:80'
EOF

    if [[ "$enable_https" == "1" ]]; then
      cat >>"$COMPOSE_FILE" <<EOF
      - '${https_port}:443'
EOF
    fi

    cat >>"$COMPOSE_FILE" <<EOF
    volumes:
      - ./proxy/decotv.conf:/etc/nginx/conf.d/default.conf:ro
      - ./proxy/www:/var/www/html:ro
      - ./proxy/certs:/etc/nginx/certs:ro
    networks: [decotv-network]
    depends_on: [decotv-core]

networks:
  decotv-network: { driver: bridge }

volumes:
  kvrocks-data: {}
EOF

  else
    # 无域名反代：对外直接暴露 host_port
    cat >"$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ${IMAGE_CORE}
    restart: on-failure
    ports: ['${host_port}:${CONTAINER_PORT}']
    env_file: [./.env]
    environment:
      - USERNAME=\${USERNAME}
      - PASSWORD=\${PASSWORD}
      - SITE_BASE=\${SITE_BASE}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks: [decotv-network]
    depends_on: [decotv-kvrocks]

  decotv-kvrocks:
    image: ${IMAGE_KVROCKS}
    restart: unless-stopped
    volumes: [kvrocks-data:/var/lib/kvrocks]
    networks: [decotv-network]

networks:
  decotv-network: { driver: bridge }

volumes:
  kvrocks-data: {}
EOF
  fi
}

install_shortcut(){
  local bin="/usr/local/bin/decotv"
  cat >"$bin" <<EOF
#!/usr/bin/env bash
exec bash "${APP_DIR}/decotv.sh" "\$@"
EOF
  chmod +x "$bin"
  log "快捷命令：decotv"
}

show_access(){
  local user="$1" pass="$2"
  local host_port="$3"
  local domain="${4:-}"
  local http_port="${5:-}"
  local https_on="${6:-0}"
  local https_port="${7:-}"

  local ip; ip="$(public_ip)"
  echo
  echo "=============================="
  echo " DecoTV 部署完成"
  echo "=============================="
  echo "管理员账号: ${user}"
  echo "管理员密码: ${pass}"

  if [[ -n "$domain" ]]; then
    if [[ "$https_on" == "1" ]]; then
      if [[ "$https_port" == "443" ]]; then
        echo "访问地址(HTTPS): https://${domain}"
      else
        echo "访问地址(HTTPS): https://${domain}:${https_port}"
      fi
    else
      if [[ "$http_port" == "80" ]]; then
        echo "访问地址(域名): http://${domain}"
      else
        echo "访问地址(域名): http://${domain}:${http_port}"
      fi
    fi
    echo "说明：域名反代由 docker 容器 decotv-proxy 提供（更稳，不依赖系统 nginx）"
  else
    echo "Docker 端口 : ${host_port}"
    echo "访问地址(IP):   http://${ip}:${host_port}"
  fi

  echo "安装目录: ${APP_DIR}"
  echo
}

do_install(){
  ensure_base
  ensure_docker
  ensure_compose

  local host_port user pass domain
  host_port="$(prompt_port "请输入 DecoTV 对外端口（无域名反代时使用）" "$DEFAULT_HOST_PORT")"
  port_in_use "$host_port" && warn "端口 ${host_port} 已被占用（如果你启用域名反代，将不会用到这个端口）"

  user="$(prompt_nonempty "请输入管理员用户名: ")"
  pass="$(prompt_password_confirm)"

  read -r -p "如需启用 域名反代(容器Nginx)，请输入绑定域名（留空则不启用）: " domain
  domain="$(trim "$domain")"

  mkdir -p "$APP_DIR"
  cp -f "$0" "${APP_DIR}/decotv.sh" >/dev/null 2>&1 || true
  chmod +x "${APP_DIR}/decotv.sh" >/dev/null 2>&1 || true

  cleanup_project

  local enable_proxy="0" http_port="" enable_https="0" https_port="" site_base=""

  if [[ -n "$domain" ]]; then
    enable_proxy="1"
    domain_dns_hint "$domain" || true

    http_port="$(pick_free_port "${HTTP_PORTS[@]}")"
    [[ -n "$http_port" ]] || { warn "找不到可用 HTTP 端口（80/8080/8880/9080/10080），将降级为直连端口"; enable_proxy="0"; }
  fi

  if [[ "$enable_proxy" == "1" ]]; then
    # 先生成 HTTP 反代配置（容器内监听 80，宿主机映射 http_port）
    write_proxy_http_conf "$domain" "$http_port"
    site_base="http://${domain}"
    [[ "$http_port" != "80" ]] && site_base="http://${domain}:${http_port}"
    write_env "$user" "$pass" "$site_base"
    write_compose "$host_port" "1" "$http_port" "0" "0"

    log "启动容器（含 decotv-proxy）..."
    compose up -d
    log "容器已启动"

    # PASSWORD 注入校验
    local core=""; core="$(detect_core_container)"
    if [[ -n "$core" ]] && ! assert_password_in_container "$core"; then
      warn "检测到容器内未读到 PASSWORD（会触发安全合规警告），自动重建一次..."
      compose down --remove-orphans >/dev/null 2>&1 || true
      compose up -d
      sleep 1
      core="$(detect_core_container)"
      if [[ -n "$core" ]] && assert_password_in_container "$core"; then
        log "PASSWORD 注入修复成功"
      else
        warn "仍未确认 PASSWORD 注入成功：请检查 ${ENV_FILE}"
      fi
    else
      log "PASSWORD 注入检查通过"
    fi

    # 可选 HTTPS：只有当 http_port==80 或者你愿意映射 80 给 proxy 才更稳
    if [[ "$http_port" == "80" ]]; then
      local yn=""
      read -r -p "是否为该域名启用 HTTPS（Let’s Encrypt/webroot，非侵入）？(y/N): " yn
      yn="$(trim "${yn:-N}")"
      if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        https_port="$(pick_free_port "${HTTPS_PORTS[@]}")"
        if [[ -z "$https_port" ]]; then
          warn "找不到可用 HTTPS 端口（443/8443/9443/10443），跳过 HTTPS"
        else
          ensure_acmesh || warn "acme.sh 安装失败，跳过 HTTPS"
          if issue_https_webroot "$domain"; then
            local ck; ck="$(export_https_files "$domain" || true)"
            if [[ -n "$ck" ]]; then
              local cert="${ck%%|*}" key="${ck#*|}"
              write_proxy_https_conf "$domain" "$cert" "$key"
              enable_https="1"
              site_base="https://${domain}"
              [[ "$https_port" != "443" ]] && site_base="https://${domain}:${https_port}"
              write_env "$user" "$pass" "$site_base"

              # 重新写 compose：把 443(容器) 映射到宿主 https_port
              write_compose "$host_port" "1" "$http_port" "1" "$https_port"
              compose up -d
              log "HTTPS 已启用：$site_base"
            else
              warn "证书导出失败，保持 HTTP 不变"
            fi
          else
            warn "证书签发失败（常见：域名未指向本机/80 不通/防火墙拦截），保持 HTTP 不变"
          fi
        fi
      fi
    else
      warn "提示：当前 HTTP 端口不是 80（而是 ${http_port}），Let’s Encrypt HTTP-01 自动签发成功率会很低。"
      warn "建议：让 80 可用再启用 HTTPS，或后续扩展 DNS 验证。"
    fi

    install_shortcut || true
    show_access "$user" "$pass" "$host_port" "$domain" "$http_port" "$enable_https" "$https_port"
    return 0
  fi

  # 降级：无域名反代（直连端口）
  write_env "$user" "$pass" ""
  write_compose "$host_port" "0" "0" "0" "0"
  log "启动容器（直连端口）..."
  compose up -d
  log "容器已启动"
  wait_ready "$host_port" || true

  # PASSWORD 注入校验
  local core=""; core="$(detect_core_container)"
  if [[ -n "$core" ]] && ! assert_password_in_container "$core"; then
    warn "检测到容器内未读到 PASSWORD（会触发安全合规警告），自动重建一次..."
    compose down --remove-orphans >/dev/null 2>&1 || true
    compose up -d
    sleep 1
  else
    log "PASSWORD 注入检查通过"
  fi

  install_shortcut || true
  show_access "$user" "$pass" "$host_port" "" "" "0" ""
}

do_update(){
  [[ -f "$COMPOSE_FILE" ]] || die "未检测到安装（${COMPOSE_FILE}），请先安装。"
  ensure_docker
  ensure_compose
  log "更新镜像：pull latest + 重建容器..."
  compose pull
  compose up -d
  log "更新完成"
}

do_status(){
  ensure_docker
  echo
  echo "容器状态："
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | (head -n1; grep -E "decotv" || true)
  echo
  if [[ -d "$PROXY_DIR" && -f "$PROXY_CONF" ]]; then
    log "已启用 容器反代：${PROXY_CONF}"
  else
    warn "未启用 容器反代"
  fi
  echo
}

do_logs(){
  ensure_docker
  local n
  echo "可选：${PROJECT_NAME}-decotv-core-1 / ${PROJECT_NAME}-decotv-kvrocks-1 / ${PROJECT_NAME}-decotv-proxy-1"
  read -r -p "输入要查看的容器名（留空默认 core）: " n
  n="$(trim "${n:-}")"
  if [[ -z "$n" ]]; then
    n="$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT_NAME}.*core" | head -n1 || true)"
  fi
  [[ -n "$n" ]] || die "找不到容器"
  docker logs --tail 200 -f "$n"
}

do_uninstall(){
  warn "将卸载本项目（仅本项目）：停止并移除容器、删除 ${APP_DIR}"
  read -r -p "确认卸载？(y/N): " yn
  yn="$(trim "${yn:-N}")"
  [[ "$yn" == "y" || "$yn" == "Y" ]] || { log "已取消"; return 0; }

  [[ -f "$COMPOSE_FILE" ]] && compose down --remove-orphans || true
  docker rm -f decotv-core decotv-kvrocks decotv-proxy >/dev/null 2>&1 || true
  rm -rf "$APP_DIR" >/dev/null 2>&1 || true

  warn "如需移除快捷命令：rm -f /usr/local/bin/decotv"
  log "卸载完成"
}

menu(){
  echo "=============================="
  echo " DecoTV · 容器域名绑定一键脚本"
  echo "=============================="
  echo "1) 安装 / 重装（容器反代绑定域名 + 可选 HTTPS + 注入校验）"
  echo "2) 更新镜像（pull latest + 重建容器）"
  echo "3) 状态查看"
  echo "4) 查看日志（tail 200 + follow）"
  echo "5) 卸载（仅移除本项目）"
  echo "0) 退出"
  read -r -p "请选择: " c
  c="$(trim "${c:-}")"
  case "$c" in
    1) do_install ;;
    2) do_update ;;
    3) do_status ;;
    4) do_logs ;;
    5) do_uninstall ;;
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac
}

main(){ need_root; menu; }
main "$@"
