#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# DecoTV 一键部署脚本（最终版：共存安全 + 纯净鸡 + 强制 HTTPS + 管道执行稳定）
#
# ✅ 目标
# - 面向公开用户：稳定、可预测、可回滚
# - HTTPS 强制：最终对外必须是 https://<domain>
# - 零侵入共存：不改 nginx.conf / 不删 default / 不覆盖他人站点
# - 证书使用 webroot：不让 certbot 自动改写 Nginx
# - 兼容管道执行：bash <(curl -fsSL ...) 或 curl|bash 也不炸（交互统一走 /dev/tty）
#
# Raw URL（用于“安装为系统命令”自下载）
#   RAW_URL=${RAW_URL:-https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh}
# =============================================================================

APP_NAME="decotv"
APP_DIR="/opt/decotv"
STATE_DIR="${APP_DIR}/state"
BACKUP_DIR="${APP_DIR}/backups"
DOMAINS_FILE="${STATE_DIR}/domains"
CREDS_FILE="${STATE_DIR}/credentials"
NGINX_MODE_FILE="${STATE_DIR}/nginx_mode"
ACME_ROOT="${ACME_ROOT:-/var/www/_acme}"

INSTALL_CMD_PATH="/usr/local/bin/decotv"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh}"

PORT="${PORT:-3000}"
KVROCKS_PORT="${KVROCKS_PORT:-6666}"

DECOTV_IMAGE="${DECOTV_IMAGE:-ghcr.io/decohererk/decotv:latest}"
KVROCKS_IMAGE="${KVROCKS_IMAGE:-apache/kvrocks:latest}"

GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"; NC="\033[0m"
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

have_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

prompt() {
  local text="$1" __var="$2" def="${3:-}" val=""
  if ! have_tty; then
    err "当前环境没有可用的 TTY（/dev/tty），无法进行交互。"
    err "请在 SSH 终端中运行，或先下载为文件再执行："
    err "  curl -fsSL \"$RAW_URL\" -o decotv.sh && bash decotv.sh"
    exit 1
  fi
  if [[ -n "$def" ]]; then
    printf "%s [%s]: " "$text" "$def" > /dev/tty
  else
    printf "%s: " "$text" > /dev/tty
  fi
  IFS= read -r val < /dev/tty || true
  val="${val:-$def}"
  printf -v "$__var" "%s" "$val"
}

confirm() {
  local text="$1" yn="N"
  prompt "$text (y/N)" yn "N"
  [[ "$yn" =~ ^[Yy]$ ]]
}

press_enter() {
  have_tty || return 0
  printf "\n按回车继续..." > /dev/tty
  IFS= read -r _ < /dev/tty || true
}

on_signal() { echo; warn "已退出脚本"; exit 0; }
trap on_signal INT TERM

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行。"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_pm() {
  if has_cmd apt-get; then echo "apt"; return; fi
  if has_cmd dnf; then echo "dnf"; return; fi
  if has_cmd yum; then echo "yum"; return; fi
  echo "unknown"
}

install_pkg() {
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y "$@" >/dev/null
      ;;
    dnf) dnf install -y "$@" >/dev/null ;;
    yum) yum install -y "$@" >/dev/null ;;
    *) err "未知包管理器，无法自动安装依赖：$*"; return 1 ;;
  esac
}

ensure_basic_deps() {
  local pkgs=()
  has_cmd curl || pkgs+=("curl")
  has_cmd tar  || pkgs+=("tar")
  has_cmd ss   || pkgs+=("iproute2")
  pkgs+=("ca-certificates")
  local pm; pm="$(detect_pm)"
  if [[ "$pm" == "apt" ]]; then pkgs+=("gnupg" "lsb-release"); fi

  local uniq=()
  for p in "${pkgs[@]}"; do [[ " ${uniq[*]} " == *" $p "* ]] || uniq+=("$p"); done
  if [[ "${#uniq[@]}" -gt 0 ]]; then
    log "检查依赖：补齐基础组件：${uniq[*]}"
    install_pkg "${uniq[@]}" || true
  fi
}

install_docker() {
  ensure_basic_deps
  if has_cmd docker; then log "Docker 已安装"; return 0; fi
  log "安装 Docker（优先包管理器，失败则使用官方脚本）"
  local pm; pm="$(detect_pm)" ok=0
  if [[ "$pm" == "apt" ]]; then
    install_pkg docker.io >/dev/null 2>&1 && ok=1 || ok=0
  elif [[ "$pm" == "dnf" || "$pm" == "yum" ]]; then
    install_pkg docker >/dev/null 2>&1 && ok=1 || ok=0
  fi
  if [[ "$ok" -ne 1 ]]; then
    warn "包管理器安装 Docker 失败，尝试 get.docker.com"
    curl -fsSL https://get.docker.com | sh && ok=1 || ok=0
  fi
  [[ "$ok" -eq 1 ]] || { err "Docker 安装失败"; return 1; }
  systemctl enable --now docker >/dev/null 2>&1 || true
  has_cmd docker || { err "Docker 安装后仍不可用"; return 1; }
  log "Docker 安装完成"
}

install_compose() {
  ensure_basic_deps
  if docker compose version >/dev/null 2>&1; then log "Docker Compose 已可用"; return 0; fi
  log "安装 Docker Compose（优先 compose plugin）"
  local pm; pm="$(detect_pm)"
  if [[ "$pm" == "apt" ]]; then
    install_pkg docker-compose-plugin >/dev/null 2>&1 || true
    docker compose version >/dev/null 2>&1 || install_pkg docker-compose >/dev/null 2>&1 || true
  elif [[ "$pm" == "dnf" || "$pm" == "yum" ]]; then
    install_pkg docker-compose-plugin >/dev/null 2>&1 || install_pkg docker-compose >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || { err "Docker Compose 安装失败"; return 1; }
  log "Docker Compose 安装完成"
}

ensure_dirs() { mkdir -p "$APP_DIR" "$STATE_DIR" "$BACKUP_DIR" "${APP_DIR}/data/kvrocks"; }


ensure_credentials() {
  ensure_dirs
  local u p
  # 若已有凭据则复用（避免每次重装都换密码）
  if [[ -f "$CREDS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CREDS_FILE" || true
    if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASS:-}" ]]; then
      export ADMIN_USER ADMIN_PASS
      {
        echo "ADMIN_USER=${ADMIN_USER}"
        echo "ADMIN_PASS=${ADMIN_PASS}"
      } > "${APP_DIR}/.env"
      return 0
    fi
  fi

  prompt "后台用户名（留空默认 admin）" u ""
  [[ -n "$u" ]] || u="admin"

  prompt "后台密码（留空自动生成强密码）" p ""
  [[ -n "$p" ]] || p="$(gen_pass)"

  ADMIN_USER="$u"
  ADMIN_PASS="$p"
  export ADMIN_USER ADMIN_PASS

  {
    echo "ADMIN_USER=${ADMIN_USER}"
    echo "ADMIN_PASS=${ADMIN_PASS}"
  } > "${APP_DIR}/.env"

  {
    echo "ADMIN_USER=${ADMIN_USER}"
    echo "ADMIN_PASS=${ADMIN_PASS}"
  } > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE" 2>/dev/null || true
}

write_compose() {
  ensure_dirs
  cat >"${APP_DIR}/docker-compose.yml" <<EOF
services:
  kvrocks:
    image: ${KVROCKS_IMAGE}
    container_name: decotv-kvrocks
    restart: unless-stopped
    ports:
      - "${KVROCKS_PORT}:6666"
    volumes:
      - "${APP_DIR}/data/kvrocks:/var/lib/kvrocks"

  decotv:
    image: ${DECOTV_IMAGE}
    container_name: decotv-app
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
    env_file:
      - .env
    environment:
      - KVROCKS_HOST=kvrocks
      - KVROCKS_PORT=6666
      - ADMIN_USER=${ADMIN_USER}
      - ADMIN_PASS=${ADMIN_PASS}
    depends_on:
      - kvrocks
EOF
}

app_up() {
  install_docker
  install_compose
  ensure_credentials
  write_compose
  (cd "$APP_DIR" && docker compose up -d)
  log "部署完成：服务端口 http://服务器IP:${PORT}"
  echo
  echo "后台用户名：${ADMIN_USER}"
  echo "后台密码：${ADMIN_PASS}"
  echo "（如应用不使用该账号体系，可忽略；脚本仍会保留并在重装时复用）"
}

app_status() { (cd "$APP_DIR" && docker compose ps) || true; }
app_start()  { (cd "$APP_DIR" && docker compose start) || true; }
app_stop()   { (cd "$APP_DIR" && docker compose stop) || true; }
app_restart(){ (cd "$APP_DIR" && docker compose restart) || true; }
app_logs()   { (cd "$APP_DIR" && docker compose logs -f --tail=200) || true; }
app_update() { (cd "$APP_DIR" && docker compose pull && docker compose up -d) || true; }

nginx_installed() { has_cmd nginx; }
nginx_active() { systemctl is-active nginx >/dev/null 2>&1; }

detect_nginx_mode() {
  if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then echo "sites"; else echo "confd"; fi
}

nginx_site_path_for_domain() {
  local domain="$1" mode
  mode="$(cat "$NGINX_MODE_FILE" 2>/dev/null || true)"
  [[ -n "$mode" ]] || mode="$(detect_nginx_mode)"
  if [[ "$mode" == "sites" ]]; then echo "/etc/nginx/sites-available/decotv-${domain}.conf"; else echo "/etc/nginx/conf.d/decotv-${domain}.conf"; fi
}

nginx_enable_site_for_domain() {
  local domain="$1" mode site
  mode="$(cat "$NGINX_MODE_FILE" 2>/dev/null || true)"
  [[ -n "$mode" ]] || mode="$(detect_nginx_mode)"
  echo "$mode" > "$NGINX_MODE_FILE"
  site="$(nginx_site_path_for_domain "$domain")"
  if [[ "$mode" == "sites" ]]; then ln -sf "$site" "/etc/nginx/sites-enabled/decotv-${domain}.conf"; fi
}

port_owner() { ss -lntp 2>/dev/null | grep -E ":[[:space:]]*$1[[:space:]]" || true; }
port_in_use_by_non_nginx() {
  local p="$1" out
  out="$(port_owner "$p")"
  [[ -z "$out" ]] && return 1
  echo "$out" | grep -qi nginx && return 1
  return 0
}

ensure_nginx_and_certbot() {
  ensure_basic_deps
  log "准备 Nginx + Certbot（共存安全）"

  if port_in_use_by_non_nginx 80 || port_in_use_by_non_nginx 443; then
    err "检测到 80/443 被非 Nginx 程序占用：无法在不破坏现有环境的前提下启用 HTTPS。"
    warn "占用情况："
    port_owner 80 || true
    port_owner 443 || true
    warn "请先让 80/443 由 Nginx 统一监听（或更换入口/机器），再继续。"
    exit 1
  fi

  if ! nginx_installed; then
    log "安装 Nginx"
    install_pkg nginx || { err "安装 nginx 失败"; exit 1; }
  else
    log "Nginx 已安装"
  fi

  local pm; pm="$(detect_pm)"
  if [[ "$pm" == "dnf" || "$pm" == "yum" ]]; then install_pkg epel-release >/dev/null 2>&1 || true; fi
  has_cmd certbot || install_pkg certbot >/dev/null 2>&1 || true
  has_cmd certbot || { err "certbot 安装失败"; exit 1; }

  systemctl enable nginx >/dev/null 2>&1 || true
  if ! nginx_active; then
    log "启动 Nginx"
    systemctl start nginx >/dev/null 2>&1 || true
  fi
}

scan_domain_conflict() {
  local domain="$1"
  nginx_installed || return 0
  local cnt
  cnt="$(nginx -T 2>/dev/null | grep -Eo "server_name\s+[^;]*" | grep -w "$domain" | wc -l | tr -d ' ')"
  if [[ "${cnt:-0}" -gt 0 ]]; then
    warn "检测到该域名已在现有 Nginx 配置中出现：$domain（次数：$cnt）"
    warn "继续可能与现有站点产生冲突。"
    confirm "仍要继续创建本项目站点配置吗？" || exit 1
  fi
}

ensure_acme_root() {
  mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
  chmod -R 755 "$ACME_ROOT" || true
}

write_nginx_http_conf() {
  local domain="$1" upstream_port="$2"
  ensure_acme_root
  local site; site="$(nginx_site_path_for_domain "$domain")"
  cat >"$site" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_ROOT};
    try_files \$uri =404;
  }

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  nginx_enable_site_for_domain "$domain"
}

ensure_nginx_https_block() {
  local domain="$1" upstream_port="$2"
  local site; site="$(nginx_site_path_for_domain "$domain")"
  grep -q "listen 443" "$site" 2>/dev/null && return 0
  cat >>"$site" <<EOF

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${domain};

  ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_ROOT};
    try_files \$uri =404;
  }

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
}

nginx_reload_safe() {
  nginx -t || { err "Nginx 配置检测失败（未 reload）"; return 1; }
  systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
  return 0
}

obtain_cert_webroot() {
  local domain="$1" email="$2"
  ensure_acme_root
  log "申请证书（webroot）：${domain}"
  certbot certonly --webroot -w "$ACME_ROOT" -d "$domain" --non-interactive --agree-tos -m "$email" --keep-until-expiring
}

setup_cert_renew() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    log "已启用 certbot.timer 自动续签"
    return 0
  fi
  (crontab -l 2>/dev/null | grep -v 'certbot renew' || true; echo "0 3 * * * certbot renew --quiet --deploy-hook \"systemctl reload nginx || nginx -s reload || true\"") | crontab -
  log "已写入 cron 自动续签（每天 03:00）"
}

record_domain() {
  ensure_dirs
  touch "$DOMAINS_FILE"
  grep -qxF "$1" "$DOMAINS_FILE" 2>/dev/null || echo "$1" >>"$DOMAINS_FILE"
}

https_enable_flow() {
  local domain email
  prompt "请输入域名（例如 tv.example.com）" domain ""
  [[ -n "$domain" ]] || { err "域名不能为空"; return 1; }
  local suggest="admin@${domain#*.}"
  prompt "请输入邮箱（可留空，不接收续期通知）" email "$suggest"
  # 允许用户输入 - 来清空邮箱
  if [[ "$email" == "-" ]]; then email=""; fi

  ensure_nginx_and_certbot
  scan_domain_conflict "$domain"

  write_nginx_http_conf "$domain" "$PORT"
  nginx_reload_safe || return 1

  obtain_cert_webroot "$domain" "$email"
  ensure_nginx_https_block "$domain" "$PORT"
  nginx_reload_safe || return 1

  setup_cert_renew
  record_domain "$domain"
  log "HTTPS 已启用：https://${domain}"
}

backup_create() {
  ensure_dirs
  local ts out tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  out="${BACKUP_DIR}/backup_${ts}.tar.gz"
  tmp="/tmp/decotv_backup_${ts}"
  log "创建备份（仅本项目相关）：$out"
  rm -rf "$tmp"; mkdir -p "$tmp"
  cp -a "$APP_DIR" "$tmp/" 2>/dev/null || true
  mkdir -p "$tmp/nginx"
  if [[ -f "$DOMAINS_FILE" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      if [[ -f "/etc/nginx/sites-available/decotv-${d}.conf" ]]; then
        mkdir -p "$tmp/nginx/sites-available" "$tmp/nginx/sites-enabled"
        cp -a "/etc/nginx/sites-available/decotv-${d}.conf" "$tmp/nginx/sites-available/" || true
        [[ -e "/etc/nginx/sites-enabled/decotv-${d}.conf" ]] && cp -a "/etc/nginx/sites-enabled/decotv-${d}.conf" "$tmp/nginx/sites-enabled/" || true
      fi
      if [[ -f "/etc/nginx/conf.d/decotv-${d}.conf" ]]; then
        mkdir -p "$tmp/nginx/conf.d"
        cp -a "/etc/nginx/conf.d/decotv-${d}.conf" "$tmp/nginx/conf.d/" || true
      fi
    done < "$DOMAINS_FILE"
  fi
  tar -czf "$out" -C "$tmp" . || { err "备份失败"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  log "备份完成：$out"
}

backup_list() { ensure_dirs; ls -lh "$BACKUP_DIR" 2>/dev/null || true; }

backup_restore() {
  ensure_dirs
  local file tmp
  prompt "请输入要恢复的备份文件完整路径" file ""
  [[ -f "$file" ]] || { err "文件不存在：$file"; return 1; }
  warn "恢复将覆盖本项目目录：$APP_DIR，并恢复本项目的 Nginx 配置文件（仅 decotv-*.conf）"
  confirm "确认恢复？" || return 0
  tmp="/tmp/decotv_restore_$$"
  rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$file" -C "$tmp"
  rm -rf "$APP_DIR" 2>/dev/null || true
  [[ -d "$tmp/opt/decotv" ]] && mkdir -p /opt && cp -a "$tmp/opt/decotv" /opt/
  if [[ -d "$tmp/nginx/sites-available" ]]; then
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cp -a "$tmp/nginx/sites-available/"* /etc/nginx/sites-available/ 2>/dev/null || true
    cp -a "$tmp/nginx/sites-enabled/"* /etc/nginx/sites-enabled/ 2>/dev/null || true
  fi
  if [[ -d "$tmp/nginx/conf.d" ]]; then
    mkdir -p /etc/nginx/conf.d
    cp -a "$tmp/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
  fi
  rm -rf "$tmp"
  nginx_installed && nginx_reload_safe || true
  if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    install_docker
    install_compose
    (cd "$APP_DIR" && docker compose up -d) || true
  fi
  log "恢复完成"
}

install_as_command() {
  ensure_basic_deps
  local target="$INSTALL_CMD_PATH"
  local self; self="$(readlink -f "$0" 2>/dev/null || true)"
  if [[ -n "${self:-}" && -f "$self" ]]; then
    install -m 0755 "$self" "$target"
    log "已安装系统命令：$target"
    log "以后直接输入：decotv"
    return 0
  fi
  warn "检测到可能是通过管道运行（无法定位脚本本地路径）。"
  warn "将从仓库下载最新版并安装为系统命令：$target"
  log "来源：$RAW_URL"
  local tmp="/tmp/decotv.$$.sh"
  curl -fsSL "$RAW_URL" -o "$tmp" || { err "下载失败：$RAW_URL"; return 1; }
  chmod 0755 "$tmp"
  mv -f "$tmp" "$target"
  log "已安装系统命令：$target"
  log "以后直接输入：decotv"
}

uninstall_all() {
  warn "将卸载 DecoTV（含数据/配置）"
  warn "仅移除本项目目录与本项目生成的 Nginx 配置，不影响其他站点。"
  confirm "确认继续？" || return 0
  [[ -f "${APP_DIR}/docker-compose.yml" ]] && (cd "$APP_DIR" && docker compose down) || true
  if [[ -f "$DOMAINS_FILE" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      rm -f "/etc/nginx/sites-enabled/decotv-${d}.conf" 2>/dev/null || true
      rm -f "/etc/nginx/sites-available/decotv-${d}.conf" 2>/dev/null || true
      rm -f "/etc/nginx/conf.d/decotv-${d}.conf" 2>/dev/null || true
    done < "$DOMAINS_FILE"
    nginx_installed && nginx_reload_safe || true
  fi
  if [[ -f "$DOMAINS_FILE" ]] && confirm "是否删除本项目域名的证书（certbot delete）？"; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      certbot delete --cert-name "$d" --non-interactive >/dev/null 2>&1 || true
    done < "$DOMAINS_FILE"
  fi
  rm -rf "$APP_DIR" 2>/dev/null || true
  rm -f "$INSTALL_CMD_PATH" 2>/dev/null || true
  log "卸载完成"
}

print_menu() {
  clear 2>/dev/null || true
  echo -e "${CYAN}DecoTV 快捷启动面板（Nginx+HTTPS+备份/恢复）${NC}"
  echo
  echo "  1) 安装/重装 DecoTV（Docker）"
  echo "  2) 查看运行状态"
  echo "  3) 启动"
  echo "  4) 停止"
  echo "  5) 重启"
  echo "  6) 查看日志"
  echo "  7) 更新（拉取新镜像并重启）"
  echo "  8) 备份（仅本项目）"
  echo "  9) 启用 HTTPS/证书（Nginx+Certbot，安全模式）"
  echo " 10) 列出备份"
  echo " 11) 恢复备份（仅本项目）"
  echo " 12) 显示当前配置"
  echo " 13) 安装为系统命令 (decotv)"
  echo " 14) 彻底卸载（含数据/配置）"
  echo "  0) 退出"
  echo
}

show_config() {
  echo "APP_DIR=$APP_DIR"
  echo "PORT=$PORT"
  echo "KVROCKS_PORT=$KVROCKS_PORT"
  echo "DECOTV_IMAGE=$DECOTV_IMAGE"
  echo "KVROCKS_IMAGE=$KVROCKS_IMAGE"
  echo "ACME_ROOT=$ACME_ROOT"
  echo "RAW_URL=$RAW_URL"
  if [[ -f "$CREDS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CREDS_FILE" || true
    [[ -n "${ADMIN_USER:-}" ]] && echo "ADMIN_USER=${ADMIN_USER}"
    [[ -n "${ADMIN_PASS:-}" ]] && echo "ADMIN_PASS=********"
  fi
  echo
  if [[ -f "$DOMAINS_FILE" ]]; then
    echo "已启用 HTTPS 的域名："
    sed 's/^/ - /' "$DOMAINS_FILE" || true
  else
    echo "已启用 HTTPS 的域名：无"
  fi
}

main_loop() {
  while true; do
    print_menu
    local choice=""
    prompt "请输入你的选择" choice ""
    case "${choice:-}" in
      1) app_up; press_enter ;;
      2) app_status; press_enter ;;
      3) app_start; log "已启动"; press_enter ;;
      4) app_stop; log "已停止"; press_enter ;;
      5) app_restart; log "已重启"; press_enter ;;
      6) app_logs ;;
      7) app_update; log "已更新"; press_enter ;;
      8) backup_create; press_enter ;;
      9) https_enable_flow; press_enter ;;
      10) backup_list; press_enter ;;
      11) backup_restore; press_enter ;;
      12) show_config; press_enter ;;
      13) install_as_command; press_enter ;;
      14) uninstall_all; press_enter ;;
      0) exit 0 ;;
      *) warn "无效选择"; press_enter ;;
    esac
  done
}

need_root
ensure_basic_deps

cmd="${1:-}"
case "$cmd" in
  ""|"menu") main_loop ;;
  install) app_up ;;
  status) app_status ;;
  start) app_start ;;
  stop) app_stop ;;
  restart) app_restart ;;
  logs) app_logs ;;
  update) app_update ;;
  backup) backup_create ;;
  https) https_enable_flow ;;
  uninstall) uninstall_all ;;
  self) install_as_command ;;
  *) err "未知命令：$cmd"; echo "可用：menu|install|status|start|stop|restart|logs|update|backup|https|uninstall|self"; exit 1 ;;
esac
gen_pass() {
  # 24 chars strong password
  local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#%^*_-+='
  local pass=""
  for _ in $(seq 1 24); do
    pass+="${chars:RANDOM%${#chars}:1}"
  done
  echo "$pass"
}

