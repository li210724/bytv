#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# =======================
# DecoTV Smart One-Click
# - Non-invasive, repeatable, auto-degrade
# - Docker + optional Nginx reverse proxy + optional HTTPS(webroot)
# =======================

APP_DIR="/opt/decotv"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
PROJECT_NAME="decotv"

IMAGE_CORE="ghcr.io/decohererk/decotv:latest"
IMAGE_KVROCKS="apache/kvrocks:latest"
CONTAINER_PORT="3000"

DEFAULT_HOST_PORT="3000"
PROXY_PORTS=(80 8080 8880 9080 10080)

NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF_FILE="$NGINX_CONF_DIR/decotv.conf"
ACME_WEBROOT="/var/www/decotv-acme"

# ----- output (no color -> avoid "乱码" in some terminals/files) -----
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
  have getent || true
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
    warn "如果要域名访问，请确认 DNS A/AAAA 指向本机。"
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

write_compose(){
  local host_port="$1"
  mkdir -p "$APP_DIR"
  # 关键：不写 container_name，杜绝重名冲突
  cat >"$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ${IMAGE_CORE}
    restart: on-failure
    ports:
      - '${host_port}:${CONTAINER_PORT}'
    env_file: [./.env]
    environment:
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks: [decotv-network]
    depends_on: [decotv-kvrocks]

  decotv-kvrocks:
    image: ${IMAGE_KVROCKS}
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks
    networks: [decotv-network]

networks:
  decotv-network:
    driver: bridge

volumes:
  kvrocks-data:
EOF
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
  # 防御：旧脚本可能写死 container_name 造成占用
  for cn in decotv-core decotv-kvrocks; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$cn"; then
      warn "发现旧固定名容器占用：$cn，自动移除..."
      docker rm -f "$cn" >/dev/null 2>&1 || true
    fi
  done
}

ensure_nginx(){
  if have nginx; then
    log "Nginx 已存在：$(nginx -v 2>&1 || true)"
  else
    warn "安装 Nginx（仅用于本项目反代，不覆盖其它站点）..."
    pm_install nginx
  fi

  mkdir -p "$NGINX_CONF_DIR" "$ACME_WEBROOT"
  systemctl enable nginx >/dev/null 2>&1 || true

  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    warn "Nginx 未运行，尝试启动..."
    if ! systemctl start nginx >/dev/null 2>&1; then
      warn "Nginx 启动失败：跳过反代（不影响 Docker 服务）"
      warn "排查：systemctl status nginx --no-pager && journalctl -xeu nginx --no-pager | tail -n 120"
      return 1
    fi
  fi
  return 0
}

nginx_apply_or_degrade(){
  # nginx -t 成功才 reload/restart
  if ! nginx -t >/dev/null 2>&1; then
    warn "Nginx 配置测试失败，移除本项目配置并降级"
    rm -f "$NGINX_CONF_FILE" >/dev/null 2>&1 || true
    return 1
  fi

  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || return 1
  else
    systemctl restart nginx >/dev/null 2>&1 || return 1
  fi
  return 0
}

write_nginx_http_conf(){
  local domain="$1" listen_port="$2" upstream_port="$3"
  cat >"$NGINX_CONF_FILE" <<EOF
# DecoTV reverse proxy (generated, non-invasive)
server {
  listen ${listen_port};
  listen [::]:${listen_port};
  server_name ${domain};

  # ACME webroot (only for this project)
  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    default_type "text/plain";
    try_files \$uri =404;
  }

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
}

write_nginx_https_conf(){
  local domain="$1" upstream_port="$2" cert="$3" key="$4"
  # HTTPS server + HTTP redirect (still only this project)
  cat >"$NGINX_CONF_FILE" <<EOF
# DecoTV reverse proxy (generated, non-invasive)

server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
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

  client_max_body_size 64m;

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
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
}

ensure_acmesh(){
  if have ~/.acme.sh/acme.sh; then return 0; fi
  if have acme.sh; then return 0; fi
  warn "安装 acme.sh（仅用于本项目 HTTPS，webroot 非侵入）..."
  curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1 || return 1
  return 0
}

issue_https_webroot(){
  local domain="$1"
  local acme="${HOME}/.acme.sh/acme.sh"
  if ! [[ -x "$acme" ]]; then
    # fallback
    acme="$(command -v acme.sh 2>/dev/null || true)"
  fi
  [[ -n "${acme:-}" ]] || return 1

  mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"

  # 使用 webroot 验证（非侵入，不停别的站）
  "$acme" --issue -d "$domain" --webroot "$ACME_WEBROOT" --keylength ec-256 >/dev/null 2>&1 \
    || "$acme" --issue -d "$domain" --webroot "$ACME_WEBROOT" >/dev/null 2>&1 \
    || return 1

  return 0
}

install_https_files(){
  local domain="$1"
  local acme="${HOME}/.acme.sh/acme.sh"
  if ! [[ -x "$acme" ]]; then
    acme="$(command -v acme.sh 2>/dev/null || true)"
  fi
  [[ -n "${acme:-}" ]] || return 1

  local outdir="/etc/ssl/decotv"
  mkdir -p "$outdir"
  local cert="${outdir}/${domain}.crt"
  local key="${outdir}/${domain}.key"

  "$acme" --install-cert -d "$domain" \
    --ecc \
    --key-file "$key" \
    --fullchain-file "$cert" \
    --reloadcmd "systemctl reload nginx || systemctl restart nginx" >/dev/null 2>&1 \
    || "$acme" --install-cert -d "$domain" \
      --key-file "$key" \
      --fullchain-file "$cert" \
      --reloadcmd "systemctl reload nginx || systemctl restart nginx" >/dev/null 2>&1 \
    || return 1

  echo "${cert}|${key}"
}

wait_ready(){
  local port="$1"
  have curl || return 0
  local base="http://127.0.0.1:${port}"
  local paths=("/" "/login" "/api" "/api/health" "/health" "/healthz")
  local i=0

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
  local user="$1" pass="$2" host_port="$3" domain="${4:-}" proxy_port="${5:-}" https="${6:-0}"
  local ip; ip="$(public_ip)"

  echo
  echo "=============================="
  echo " DecoTV 部署完成"
  echo "=============================="
  echo "管理员账号: ${user}"
  echo "管理员密码: ${pass}"
  echo "Docker 端口 : ${host_port}"
  if [[ "$https" == "1" && -n "$domain" ]]; then
    echo "访问地址(HTTPS): https://${domain}"
  elif [[ -n "$domain" && -n "$proxy_port" ]]; then
    [[ "$proxy_port" == "80" ]] && echo "访问地址(域名): http://${domain}" || echo "访问地址(域名): http://${domain}:${proxy_port}"
  else
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
  host_port="$(prompt_port "请输入 DecoTV 对外端口 " "$DEFAULT_HOST_PORT")"
  port_in_use "$host_port" && die "端口 ${host_port} 已被占用，请换一个端口。"

  user="$(prompt_nonempty "请输入管理员用户名: ")"
  pass="$(prompt_password_confirm)"

  read -r -p "如需启用 Nginx 反代，请输入绑定域名（留空则不启用）: " domain
  domain="$(trim "$domain")"

  mkdir -p "$APP_DIR"
  cp -f "$0" "${APP_DIR}/decotv.sh" >/dev/null 2>&1 || true
  chmod +x "${APP_DIR}/decotv.sh" >/dev/null 2>&1 || true

  write_compose "$host_port"
  write_env "$user" "$pass" ""

  cleanup_project

  log "启动容器..."
  compose up -d
  log "容器已启动"
  wait_ready "$host_port" || true

  local proxy_port="" https_enabled="0"

  if [[ -n "$domain" ]]; then
    domain_dns_hint "$domain" || true

    if ensure_nginx; then
      proxy_port="$(pick_free_port "${PROXY_PORTS[@]}")"
      if [[ -z "$proxy_port" ]]; then
        warn "未找到可用反代端口（80/8080/8880/9080/10080 全占用），跳过反代。"
        domain=""
      else
        [[ "$proxy_port" != "80" ]] && warn "为避免冲突，本项目反代端口使用：${proxy_port}"

        # 先上 HTTP 反代（无论是否后续 HTTPS）
        write_nginx_http_conf "$domain" "$proxy_port" "$host_port"
        if nginx_apply_or_degrade; then
          log "HTTP 反代已生效：${NGINX_CONF_FILE}"
          [[ "$proxy_port" == "80" ]] && write_env "$user" "$pass" "http://${domain}" || write_env "$user" "$pass" "http://${domain}:${proxy_port}"
          compose up -d
        else
          warn "Nginx 生效失败，自动降级为仅 Docker 端口访问。"
          domain=""; proxy_port=""
        fi

        # 可选 HTTPS（仅当 80 可用且正在使用 80）
        if [[ -n "$domain" && "$proxy_port" == "80" ]]; then
          local yn=""
          read -r -p "是否为该域名启用 HTTPS（Let’s Encrypt/webroot，非侵入）？(y/N): " yn
          yn="$(trim "${yn:-N}")"
          if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
            if ensure_acmesh; then
              log "尝试签发证书（HTTP-01/webroot）..."
              if issue_https_webroot "$domain"; then
                local ck; ck="$(install_https_files "$domain" || true)"
                if [[ -n "$ck" ]]; then
                  local cert="${ck%%|*}" key="${ck#*|}"
                  write_nginx_https_conf "$domain" "$host_port" "$cert" "$key"
                  if nginx_apply_or_degrade; then
                    https_enabled="1"
                    write_env "$user" "$pass" "https://${domain}"
                    compose up -d
                    log "HTTPS 已启用：https://${domain}"
                  else
                    warn "HTTPS 配置应用失败，保持 HTTP 不变。"
                    # revert back to http conf
                    write_nginx_http_conf "$domain" "80" "$host_port"
                    nginx_apply_or_degrade || true
                  fi
                else
                  warn "证书安装失败，保持 HTTP 不变。"
                fi
              else
                warn "证书签发失败（常见原因：域名未指向本机/80 未通/防火墙拦截），保持 HTTP 不变。"
              fi
            else
              warn "acme.sh 安装失败，保持 HTTP 不变。"
            fi
          fi
        elif [[ -n "$domain" && "$proxy_port" != "80" ]]; then
          warn "提示：你当前反代端口不是 80（而是 ${proxy_port}），无法做 Let’s Encrypt HTTP-01 自动签发。"
          warn "如需 HTTPS：请确保 80 可用并使用 80 反代，或改用 DNS 验证（可后续扩展）。"
        fi
      fi
    else
      domain=""; proxy_port=""
    fi
  fi

  install_shortcut || true
  show_access "$user" "$pass" "$host_port" "$domain" "$proxy_port" "$https_enabled"
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
  [[ -f "$NGINX_CONF_FILE" ]] && log "Nginx 配置：${NGINX_CONF_FILE}" || warn "未启用/未生成本项目 Nginx 配置"
  echo
}

do_logs(){
  ensure_docker
  local n
  read -r -p "要查看的容器名（默认 decotv-core，可选 decotv-kvrocks）: " n
  n="$(trim "${n:-decotv-core}")"
  docker logs --tail 200 -f "$n"
}

do_uninstall(){
  warn "将卸载本项目（仅本项目）：停止并移除容器、删除 ${APP_DIR}、移除 ${NGINX_CONF_FILE}"
  read -r -p "确认卸载？(y/N): " yn
  yn="$(trim "${yn:-N}")"
  [[ "$yn" == "y" || "$yn" == "Y" ]] || { log "已取消"; return 0; }

  [[ -f "$COMPOSE_FILE" ]] && compose down --remove-orphans || true
  docker rm -f decotv-core decotv-kvrocks >/dev/null 2>&1 || true
  rm -rf "$APP_DIR" >/dev/null 2>&1 || true
  rm -f "$NGINX_CONF_FILE" >/dev/null 2>&1 || true

  if have nginx; then
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true) || true
  fi

  warn "如需移除快捷命令：rm -f /usr/local/bin/decotv"
  log "卸载完成"
}

menu(){
  echo "=============================="
  echo " DecoTV · 智能一键部署脚本"
  echo "=============================="
  echo "1) 安装 / 重装（智能清理 + 可选反代 + 可选 HTTPS + 自动降级）"
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
