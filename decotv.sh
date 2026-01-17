#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# DecoTV Full Ops Script (Nginx + Let's Encrypt + Backup)
# Maintainer repo (this script): https://github.com/li210724/bytv
#
# Highlights:
#  - One menu to install & operate DecoTV (Docker Compose)
#  - Optional Nginx reverse proxy + Let's Encrypt HTTPS (certbot)
#  - Domain DNS -> local IP check (to avoid cert failures)
#  - Backup / Restore
#  - Update / Logs / Status
#  - Full uninstall (containers + data + nginx conf + command)
#
# Security note:
#  - This script supports "install as command" even when run via curl|bash,
#    by downloading the pinned RAW script into /usr/local/bin/decotv.
# ==========================================================

APP_NAME="decotv"
APP_DIR="${APP_DIR:-/opt/decotv}"
DATA_DIR="$APP_DIR/data"
BACKUP_DIR="$APP_DIR/backups"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

IMAGE="${IMAGE:-ghcr.io/decohererk/decotv:latest}"
PORT="${PORT:-3000}"           # host port -> container 3000 (nginx proxies to this)
DOMAIN="${DOMAIN:-}"           # set during install / https
EMAIL="${EMAIL:-}"             # cert email

# Where to fetch the latest script if current runtime path is not a real file
SCRIPT_RAW_URL="${SCRIPT_RAW_URL:-https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh}"
INSTALL_CMD_PATH="${INSTALL_CMD_PATH:-/usr/local/bin/decotv}"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 执行${NC}" && exit 1

log()  { echo -e "${GREEN}[+] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
err()  { echo -e "${RED}[-] $*${NC}"; }

pause() { read -rp "回车继续..." _ || true; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_ip() {
  curl -s ipv4.icanhazip.com || curl -s ifconfig.me || true
}

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
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    *)
      err "不支持的系统包管理器，请手动安装: $*"
      exit 1
      ;;
  esac
}

install_docker() {
  if has_cmd docker; then return; fi
  log "安装 Docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

install_compose() {
  if docker compose version >/dev/null 2>&1; then return; fi
  log "安装 docker compose v2 插件"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

dns_ip() {
  local domain="$1"
  if has_cmd dig; then
    dig +short A "$domain" | head -n1
    return
  fi
  ping -c1 "$domain" 2>/dev/null | sed -n '1s/.*(\(.*\)).*/\1/p'
}

check_domain_points_to_local() {
  local domain="$1"
  local local_ip domain_ip
  local_ip="$(get_ip)"
  if [[ -z "$local_ip" ]]; then
    warn "无法自动获取本机公网 IP，将跳过解析校验"
    return 0
  fi
  domain_ip="$(dns_ip "$domain" || true)"
  if [[ -z "$domain_ip" ]]; then
    err "无法解析域名：$domain"
    exit 1
  fi
  if [[ "$domain_ip" == "$local_ip" ]]; then
    log "域名已正确解析到本机 ($local_ip)"
  else
    err "域名解析未指向本机"
    echo "  域名 IP: $domain_ip"
    echo "  本机 IP: $local_ip"
    exit 1
  fi
}

ufw_open_ports_if_any() {
  if ! has_cmd ufw; then return 0; fi
  if ! ufw status 2>/dev/null | grep -qi "Status: active"; then return 0; fi
  warn "检测到 ufw 已启用，尝试放行 80/443/${PORT}"
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow "${PORT}/tcp" || true
}

write_compose() {
  mkdir -p "$APP_DIR" "$DATA_DIR" "$BACKUP_DIR"

  cat >"$COMPOSE_FILE" <<EOF
version: "3.8"
services:
  kvrocks:
    image: apache/kvrocks
    restart: always
    volumes:
      - ./data:/data

  decotv:
    image: ${IMAGE}
    restart: always
    ports:
      - "${PORT}:3000"
    environment:
      USERNAME: "${USERNAME}"
      PASSWORD: "${PASSWORD}"
      NEXT_PUBLIC_STORAGE_TYPE: kvrocks
      KVROCKS_URL: redis://kvrocks:6666
    depends_on:
      - kvrocks
EOF
}

compose_up()   { docker compose -f "$COMPOSE_FILE" up -d; }
compose_down() { docker compose -f "$COMPOSE_FILE" down || true; }
compose_down_volumes() { docker compose -f "$COMPOSE_FILE" down -v || true; }

install_nginx_certbot() {
  log "安装 Nginx + Certbot"
  install_pkg nginx

  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt) install_pkg certbot python3-certbot-nginx ;;
    dnf|yum) install_pkg certbot python3-certbot-nginx || install_pkg certbot python3-certbot || true ;;
  esac

  systemctl enable --now nginx
}

nginx_site_path() { echo "/etc/nginx/sites-available/${APP_NAME}.conf"; }
nginx_site_link() { echo "/etc/nginx/sites-enabled/${APP_NAME}.conf"; }

write_nginx_http_conf() {
  local domain="$1"
  local site; site="$(nginx_site_path)"

  cat >"$site" <<EOF
# Auto-generated by ${APP_NAME} script
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # ACME challenge (certbot)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  if [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf "$site" "$(nginx_site_link)"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  fi

  nginx -t
  systemctl reload nginx
}

obtain_https_cert() {
  local domain="$1"
  local email="$2"

  if ! has_cmd certbot; then
    err "certbot 未安装"
    exit 1
  fi

  log "申请 Let's Encrypt 证书 (certbot --nginx)"
  certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect
  systemctl reload nginx
  log "证书申请完成"
}

setup_cert_renew() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^certbot.timer"; then
    systemctl enable --now certbot.timer || true
    log "已启用 certbot.timer 自动续期"
    return
  fi

  if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
    log "已写入 cron 自动续期（每天 03:00）"
  fi
}

install_flow() {
  log "开始部署 DecoTV"

  read -rp "后台用户名: " USERNAME
  read -rp "后台密码: " PASSWORD

  read -rp "是否启用域名反代(Nginx)? (y/N): " yn
  local use_nginx=0
  local with_https=0
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    use_nginx=1
    read -rp "请输入域名(例如 tv.example.com): " DOMAIN
    check_domain_points_to_local "$DOMAIN"

    read -rp "是否自动申请 HTTPS 证书(Let's Encrypt)? (y/N): " yn2
    if [[ "$yn2" =~ ^[Yy]$ ]]; then
      with_https=1
      read -rp "证书注册邮箱(用于到期通知): " EMAIL
      [[ -z "$EMAIL" ]] && err "邮箱不能为空" && exit 1
    fi
  fi

  install_docker
  install_compose

  write_compose
  compose_up

  ufw_open_ports_if_any

  if [[ "$use_nginx" == "1" ]]; then
    install_nginx_certbot
    write_nginx_http_conf "$DOMAIN"
    if [[ "$with_https" == "1" ]]; then
      obtain_https_cert "$DOMAIN" "$EMAIL"
      setup_cert_renew
    else
      warn "未启用 HTTPS：你可以稍后用“启用 HTTPS/证书”或命令 decotv https 启用"
    fi
  fi

  log "部署完成"
  if [[ "$use_nginx" == "1" ]]; then
    if [[ "$with_https" == "1" ]]; then
      echo "访问地址: https://${DOMAIN}"
    else
      echo "访问地址: http://${DOMAIN}"
    fi
  else
    echo "访问地址: http://$(get_ip):${PORT}"
  fi
}

ensure_installed() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "未检测到安装：$COMPOSE_FILE 不存在"
    exit 1
  fi
}

status()  { ensure_installed; docker compose -f "$COMPOSE_FILE" ps; }
start()   { ensure_installed; docker compose -f "$COMPOSE_FILE" up -d; log "已启动"; }
stop()    { ensure_installed; docker compose -f "$COMPOSE_FILE" down; log "已停止"; }
restart() { ensure_installed; docker compose -f "$COMPOSE_FILE" restart; log "已重启"; }
logs()    { ensure_installed; docker compose -f "$COMPOSE_FILE" logs --tail 200 -f; }

update_image() {
  ensure_installed
  log "拉取最新镜像并更新"
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  log "更新完成"
}

https_enable_flow() {
  ensure_installed
  [[ -z "${DOMAIN}" ]] && read -rp "请输入域名(例如 tv.example.com): " DOMAIN
  check_domain_points_to_local "$DOMAIN"
  [[ -z "${EMAIL}" ]] && read -rp "证书注册邮箱(用于到期通知): " EMAIL
  [[ -z "${EMAIL}" ]] && err "邮箱不能为空" && exit 1

  install_nginx_certbot
  write_nginx_http_conf "$DOMAIN"
  obtain_https_cert "$DOMAIN" "$EMAIL"
  setup_cert_renew

  log "HTTPS 已启用：https://${DOMAIN}"
}

backup_create() {
  ensure_installed
  mkdir -p "$BACKUP_DIR"
  local ts file tmp_tar
  ts="$(date +%Y%m%d_%H%M%S)"
  file="$BACKUP_DIR/${APP_NAME}_backup_${ts}.tar.gz"
  tmp_tar="${file%.gz}"

  log "创建备份：$file"
  tar -cf "$tmp_tar" -C "$APP_DIR" "data" "docker-compose.yml" 2>/dev/null || true
  if [[ -f "$(nginx_site_path)" ]]; then
    tar -rf "$tmp_tar" -C / "$(nginx_site_path)" 2>/dev/null || true
  fi
  gzip -f "$tmp_tar" 2>/dev/null || true

  log "备份完成"
  echo "$file"
}

backup_list() { mkdir -p "$BACKUP_DIR"; ls -lah "$BACKUP_DIR" || true; }

backup_restore() {
  ensure_installed
  mkdir -p "$BACKUP_DIR"
  read -rp "请输入备份文件完整路径(.tar.gz): " BK
  [[ ! -f "$BK" ]] && err "文件不存在：$BK" && exit 1

  warn "恢复会覆盖当前数据与配置"
  read -rp "确认恢复? 输入 yes: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && exit 0

  stop
  log "解压恢复到 $APP_DIR"
  mkdir -p "$APP_DIR"
  tar -xzf "$BK" -C "$APP_DIR" || true

  if tar -tzf "$BK" | grep -q "^etc/nginx"; then
    warn "检测到 Nginx 配置备份，将恢复到系统目录"
    tar -xzf "$BK" -C / --overwrite || true
    nginx -t && systemctl reload nginx || true
  fi

  start
  log "恢复完成"
}

uninstall_all() {
  warn "即将彻底卸载 DecoTV（容器+数据+Nginx配置+命令）"
  read -rp "确认卸载? 输入 yes: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && exit 0

  if [[ -f "$COMPOSE_FILE" ]]; then
    compose_down_volumes
  fi

  rm -rf "$APP_DIR"
  rm -f "$(nginx_site_path)" "$(nginx_site_link)" 2>/dev/null || true
  systemctl reload nginx 2>/dev/null || true
  rm -f "$INSTALL_CMD_PATH" 2>/dev/null || true

  log "卸载完成"
}

install_as_command() {
  local target="$INSTALL_CMD_PATH"
  local self; self="$(readlink -f "$0" 2>/dev/null || true)"

  # If current script is a normal file, install from it
  if [[ -n "$self" && -f "$self" && "$self" != /proc/*/fd/* ]]; then
    cp -f "$self" "$target"
    chmod +x "$target"
    log "已安装快捷指令：$(basename "$target")"
  else
    # Running via pipe/FD; download from RAW URL
    warn "检测到脚本可能通过 curl|bash 方式运行（非落盘文件）"
    warn "将从仓库 RAW 地址下载脚本并安装为系统命令：$target"
    if ! has_cmd curl; then
      err "curl 未安装，无法下载脚本"
      exit 1
    fi
    curl -fsSL "$SCRIPT_RAW_URL" -o "$target"
    chmod +x "$target"
    log "已下载并安装快捷指令：$(basename "$target")"
  fi

  echo
  echo "现在你可以直接使用："
  echo "  decotv            # 打开快捷启动面板"
  echo "  decotv status     # 查看状态"
  echo "  decotv https      # 启用/修复 HTTPS 证书"
  echo "  decotv backup     # 创建备份"
  echo
}

show_info() {
  echo "------------------------------"
  echo "App: ${APP_NAME}"
  echo "Dir: ${APP_DIR}"
  echo "Compose: ${COMPOSE_FILE}"
  echo "Image: ${IMAGE}"
  echo "Port: ${PORT}"
  [[ -n "${DOMAIN}" ]] && echo "Domain: ${DOMAIN}"
  echo "Public IP: $(get_ip)"
  echo "------------------------------"
}

menu() {
  while true; do
    clear || true
    echo "=============================================="
    echo "  DecoTV 快捷启动面板  (Nginx+HTTPS+备份/恢复)"
    echo "=============================================="
    echo " 1) 安装/部署"
    echo " 2) 信息"
    echo " 3) 状态"
    echo " 4) 启动"
    echo " 5) 停止"
    echo " 6) 重启"
    echo " 7) 查看日志 (tail -f)"
    echo " 8) 更新镜像"
    echo " 9) 启用 HTTPS/证书 (Nginx+Certbot)"
    echo "10) 创建备份"
    echo "11) 备份列表"
    echo "12) 恢复备份"
    echo "13) 安装为系统命令(decotv)"
    echo "14) 彻底卸载(含数据/配置)"
    echo " 0) 退出"
    echo "----------------------------------------------"
    read -rp "请选择: " CHOICE
    case "$CHOICE" in
      1) install_flow; pause ;;
      2) show_info; pause ;;
      3) status; pause ;;
      4) start; pause ;;
      5) stop; pause ;;
      6) restart; pause ;;
      7) logs ;;
      8) update_image; pause ;;
      9) https_enable_flow; pause ;;
      10) backup_create; pause ;;
      11) backup_list; pause ;;
      12) backup_restore; pause ;;
      13) install_as_command; pause ;;
      14) uninstall_all; pause ;;
      0) exit 0 ;;
      *) err "无效选项"; pause ;;
    esac
  done
}

usage() {
  cat <<EOF
用法:
  decotv                 打开快捷启动面板(交互菜单)
  decotv install         交互安装/部署
  decotv info            显示信息
  decotv status          查看状态
  decotv start|stop      启动/停止
  decotv restart         重启
  decotv logs            跟随日志
  decotv update          更新镜像并重启容器
  decotv https           启用/修复 Nginx + HTTPS 证书
  decotv backup          创建备份
  decotv backups         列出备份
  decotv restore         恢复备份(交互输入文件)
  decotv cmd             安装为系统命令 /usr/local/bin/decotv
  decotv uninstall       彻底卸载(含数据/配置)

环境变量(可选):
  SCRIPT_RAW_URL         作为命令安装时的脚本下载地址
  APP_DIR PORT IMAGE     自定义部署目录/端口/镜像
EOF
}

# ---------- CLI entry ----------
cmd="${1:-}"
case "$cmd" in
  ""|"menu") menu ;;
  "install") install_flow ;;
  "info") show_info ;;
  "status") status ;;
  "start") start ;;
  "stop") stop ;;
  "restart") restart ;;
  "logs") logs ;;
  "update") update_image ;;
  "https") https_enable_flow ;;
  "backup") backup_create ;;
  "backups") backup_list ;;
  "restore") backup_restore ;;
  "cmd") install_as_command ;;
  "uninstall") uninstall_all ;;
  "-h"|"--help"|"help") usage ;;
  *) err "未知命令：$cmd"; usage; exit 1 ;;
esac
