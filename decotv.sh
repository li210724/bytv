#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DecoTV 一键部署运维脚本（安全共存版）
# Repo: https://github.com/li210724/bytv
#
# 设计目标：
#  - 不碰别人站点：只“新增”自己的 Nginx 配置，不覆盖、不删除 default、不重启 nginx
#  - 能共存科技lion/Komari/其他站点：避免 80/443 端口抢占导致别人站点挂
#  - 交互式菜单：部署 / HTTPS / 备份恢复 / 更新 / 卸载 / 安装为命令
#
# 注意：
#  - 本脚本负责部署与运维，不修改 DecoTV 源码
#  - HTTPS 使用 certbot --nginx（会修改“本脚本生成的站点配置”，不会改其他站点）
# ==============================================================================

APP_NAME="decotv"
APP_DIR="${APP_DIR:-/opt/decotv}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
STATE_DIR="${APP_DIR}/.state"
DOMAINS_FILE="${STATE_DIR}/domains"
NGINX_DIR_AVAILABLE="/etc/nginx/sites-available"
NGINX_DIR_ENABLED="/etc/nginx/sites-enabled"
INSTALL_CMD_PATH="/usr/local/bin/decotv"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh}"

# Default container mapping
PORT="${PORT:-3000}"                 # host port -> container 3000
IMAGE="${IMAGE:-ghcr.io/decohererk/decotv:latest}"
KVROCKS_IMAGE="${KVROCKS_IMAGE:-apache/kvrocks:latest}"

# Colors
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; NC="\033[0m"
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

pause() { read -rp "回车继续..." _ || true; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 运行"
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
  local pkgs=("$@")
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    *)
      err "未知包管理器，无法自动安装：${pkgs[*]}"
      return 1
      ;;
  esac
}

get_public_ipv4() {
  curl -fsSL ipv4.icanhazip.com 2>/dev/null || curl -fsSL ifconfig.me 2>/dev/null || true
}

resolve_domain_ipv4() {
  local d="$1"
  # getent 优先，其次 dig
  if has_cmd getent; then
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -n1 || true
  elif has_cmd dig; then
    dig +short A "$d" 2>/dev/null | head -n1 || true
  else
    # 最差方案：ping 解析
    ping -c1 "$d" 2>/dev/null | sed -n 's/.*(\([0-9.]\+\)).*/\1/p' | head -n1 || true
  fi
}

check_domain_points_to_local() {
  local d="$1"
  local pub; pub="$(get_public_ipv4)"
  local dip; dip="$(resolve_domain_ipv4 "$d")"

  if [[ -z "$pub" ]]; then
    warn "无法获取本机公网 IPv4，跳过解析校验（建议安装 curl 并确保可访问外网）"
    return 0
  fi
  if [[ -z "$dip" ]]; then
    warn "无法解析域名 IPv4：$d（可能未生效/使用 AAAA/被污染）。如确认无误可继续。"
    read -rp "仍要继续吗？(y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
    return 0
  fi

  if [[ "$dip" != "$pub" ]]; then
    warn "域名解析 IPv4 不匹配："
    warn "  域名 A 记录: $dip"
    warn "  本机公网 IPv4: $pub"
    warn "继续申请证书可能失败或申请到错误机器。"
    read -rp "仍要继续吗？(y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
  else
    log "域名解析校验通过：$d -> $dip"
  fi
}

ensure_dirs() {
  mkdir -p "$APP_DIR" "$STATE_DIR" "$APP_DIR/backups"
  touch "$DOMAINS_FILE"
}

record_domain() {
  local d="$1"
  ensure_dirs
  grep -qxF "$d" "$DOMAINS_FILE" 2>/dev/null || echo "$d" >>"$DOMAINS_FILE"
}

list_recorded_domains() {
  ensure_dirs
  sed '/^\s*$/d' "$DOMAINS_FILE" 2>/dev/null || true
}

install_docker() {
  if has_cmd docker; then
    log "Docker 已安装"
    return 0
  fi
  log "安装 Docker"
  install_pkg ca-certificates curl gnupg lsb-release
  if has_cmd apt-get; then
    install_pkg docker.io
  else
    install_pkg docker
  fi
  systemctl enable --now docker || true
}

install_compose() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose 已可用"
    return 0
  fi
  # 尝试安装 compose plugin
  log "安装 Docker Compose"
  if has_cmd apt-get; then
    install_pkg docker-compose-plugin
  elif has_cmd dnf || has_cmd yum; then
    install_pkg docker-compose-plugin || install_pkg docker-compose || true
  fi
  docker compose version >/dev/null 2>&1 || { err "Docker Compose 安装失败"; return 1; }
}

write_compose() {
  ensure_dirs
  local username password
  read -rp "后台用户名: " username
  read -rp "后台密码: " password
  [[ -z "$username" || -z "$password" ]] && err "用户名/密码不能为空" && exit 1

  cat >"$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  kvrocks:
    image: ${KVROCKS_IMAGE}
    restart: always
    volumes:
      - ./kvrocks-data:/data

  decotv:
    image: ${IMAGE}
    restart: always
    ports:
      - "${PORT}:3000"
    environment:
      USERNAME: "${username}"
      PASSWORD: "${password}"
      NEXT_PUBLIC_STORAGE_TYPE: kvrocks
      KVROCKS_URL: redis://kvrocks:6666
    depends_on:
      - kvrocks
EOF

  log "已写入 Compose：$COMPOSE_FILE"
}

compose_up()   { docker compose -f "$COMPOSE_FILE" up -d; }
compose_down() { docker compose -f "$COMPOSE_FILE" down || true; }
compose_down_volumes() { docker compose -f "$COMPOSE_FILE" down -v || true; }

ensure_installed() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "未检测到安装：$COMPOSE_FILE"
    err "请先选择 1) 安装/部署"
    exit 1
  fi
}

show_info() {
  ensure_dirs
  echo
  echo "=============================="
  echo " ${APP_NAME} 信息"
  echo "=============================="
  echo "安装目录: $APP_DIR"
  echo "Compose:  $COMPOSE_FILE"
  echo "镜像:     $IMAGE"
  echo "端口:     $PORT -> 3000"
  echo "已记录域名:"
  list_recorded_domains | sed 's/^/  - /' || true
  echo "=============================="
  echo
}

status()  { ensure_installed; docker compose -f "$COMPOSE_FILE" ps; }
start_app()   { ensure_installed; compose_up; log "已启动"; }
stop_app()    { ensure_installed; compose_down; log "已停止"; }
restart_app() { ensure_installed; docker compose -f "$COMPOSE_FILE" restart; log "已重启"; }
logs_app()    { ensure_installed; docker compose -f "$COMPOSE_FILE" logs --tail 200 -f; }

update_image() {
  ensure_installed
  log "拉取最新镜像并更新"
  docker compose -f "$COMPOSE_FILE" pull
  docker compose -f "$COMPOSE_FILE" up -d
  log "更新完成"
}

# ----------------------- Nginx safe coexist helpers -----------------------

nginx_is_installed() { has_cmd nginx && [[ -d "$NGINX_DIR_AVAILABLE" ]]; }

nginx_active() { systemctl is-active nginx >/dev/null 2>&1; }

port_in_use_by_non_nginx() {
  # return 0 if 80 is used by something other than nginx
  if ! has_cmd ss; then install_pkg iproute2 >/dev/null 2>&1 || true; fi
  local out
  out="$(ss -lntp 2>/dev/null | awk '$4 ~ /:80$/ {print}' || true)"
  [[ -z "$out" ]] && return 1
  echo "$out" | grep -q "nginx" && return 1
  return 0
}

backup_nginx_before_change() {
  # Only backup once per run; safe and lightweight
  ensure_dirs
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local bk="$APP_DIR/backups/nginx-sites-$ts.tar.gz"
  if [[ -d "$NGINX_DIR_AVAILABLE" || -d "$NGINX_DIR_ENABLED" ]]; then
    tar -czf "$bk" "$NGINX_DIR_AVAILABLE" "$NGINX_DIR_ENABLED" 2>/dev/null || true
    log "已备份 Nginx 站点配置到：$bk"
  fi
}

ensure_nginx_certbot() {
  log "安装 Nginx + Certbot（共存模式：不重启/不删除他人站点）"

  # 安装 nginx（注意：某些系统安装后会尝试启动；这是系统行为，不由脚本强控）
  if ! nginx_is_installed; then
    install_pkg nginx
  else
    log "Nginx 已安装"
  fi

  # 安装 certbot
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt) install_pkg certbot python3-certbot-nginx ;;
    dnf|yum) install_pkg certbot python3-certbot-nginx || install_pkg certbot python3-certbot || true ;;
    *) install_pkg certbot || true ;;
  esac

  # 不强制 restart nginx：如果当前 nginx 正在服务其他站点，重启会造成短暂中断
  systemctl enable nginx >/dev/null 2>&1 || true

  if port_in_use_by_non_nginx; then
    err "检测到 80 端口被非 Nginx 程序占用，无法安全启用反代。"
    err "请先释放 80（或迁移到 Nginx），再启用 HTTPS/反代。"
    ss -lntp 2>/dev/null | grep ':80' || true
    exit 1
  fi
}

nginx_site_path_for_domain() {
  # create a unique file per domain to avoid collisions
  local d="$1"
  local safe="${d//[^a-zA-Z0-9._-]/_}"
  echo "${NGINX_DIR_AVAILABLE}/${APP_NAME}-${safe}.conf"
}

nginx_link_path_for_domain() {
  local d="$1"
  local safe="${d//[^a-zA-Z0-9._-]/_}"
  echo "${NGINX_DIR_ENABLED}/${APP_NAME}-${safe}.conf"
}

write_nginx_proxy_http_conf() {
  local domain="$1"
  local upstream_port="$2"

  backup_nginx_before_change

  mkdir -p "$NGINX_DIR_AVAILABLE" "$NGINX_DIR_ENABLED"

  local site; site="$(nginx_site_path_for_domain "$domain")"
  cat >"$site" <<EOF
# Auto-generated by ${APP_NAME} script (safe coexist mode)
# Domain: ${domain}
# Upstream: http://127.0.0.1:${upstream_port}
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  # Keep other sites untouched. This server block is ONLY for ${domain}.
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

  ln -sf "$site" "$(nginx_link_path_for_domain "$domain")"

  nginx -t
  # 关键：不 restart，只 reload（避免影响其他站点）
  if nginx_active; then
    systemctl reload nginx
  else
    # 如果 nginx 没在跑，就 start（此时不会“重启别人”，因为根本没在跑）
    systemctl start nginx || true
    nginx_active && log "Nginx 已启动" || warn "Nginx 启动失败（可能端口冲突），但配置已写入。请手动排查后再启动。"
  fi

  record_domain "$domain"
  log "已写入并启用 Nginx 站点：$site"
}

obtain_https_cert() {
  local domain="$1"
  local email="$2"

  has_cmd certbot || { err "certbot 未安装"; exit 1; }

  log "申请 Let's Encrypt 证书（仅作用于 ${domain}，不会覆盖其他站点）"
  # certbot --nginx 会在匹配 server_name 的站点上插入 443/证书配置
  certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect

  if nginx_active; then
    systemctl reload nginx
  else
    systemctl start nginx || true
  fi
  log "证书申请完成：${domain}"
}

setup_cert_renew() {
  # 自动续期：优先 systemd timer，其次 cron 兜底
  if systemctl list-unit-files 2>/dev/null | grep -q "^certbot.timer"; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    log "已启用 certbot.timer 自动续期"
    return
  fi

  if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
    log "已写入 cron 自动续期（每天 03:00）"
  fi
}

https_enable_flow() {
  ensure_installed
  local domain email
  read -rp "请输入域名(例如 tv.example.com): " domain
  [[ -z "$domain" ]] && err "域名不能为空" && exit 1

  check_domain_points_to_local "$domain"
  ensure_nginx_certbot

  # 写入仅针对该域名的 80 反代（不动 default / 不动其他站点）
  write_nginx_proxy_http_conf "$domain" "$PORT"

  read -rp "是否申请/启用 HTTPS 证书(Let's Encrypt)? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -rp "证书注册邮箱(用于到期通知): " email
    [[ -z "$email" ]] && err "邮箱不能为空" && exit 1
    obtain_https_cert "$domain" "$email"
    setup_cert_renew
    log "HTTPS 已启用：https://${domain}"
  else
    log "已启用 HTTP 反代：http://${domain}"
  fi
}

# -------------------------- Backup / Restore --------------------------

backup_create() {
  ensure_installed
  ensure_dirs
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local out="$APP_DIR/backups/backup-$ts.tar.gz"

  # 只备份“本项目相关”的内容：APP_DIR + 我们生成的 nginx conf（按记录域名）
  local tmpdir; tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/nginx/sites-available" "$tmpdir/nginx/sites-enabled"

  while read -r d; do
    [[ -z "$d" ]] && continue
    local p1 p2
    p1="$(nginx_site_path_for_domain "$d")"
    p2="$(nginx_link_path_for_domain "$d")"
    [[ -f "$p1" ]] && cp -a "$p1" "$tmpdir/nginx/sites-available/" || true
    [[ -L "$p2" || -f "$p2" ]] && cp -a "$p2" "$tmpdir/nginx/sites-enabled/" || true
  done < <(list_recorded_domains)

  tar -czf "$out" -C / "${APP_DIR#/}" -C "$tmpdir" nginx 2>/dev/null || true
  rm -rf "$tmpdir" || true
  log "备份完成：$out"
}

backup_list() {
  ensure_dirs
  ls -lh "$APP_DIR/backups" 2>/dev/null || true
}

backup_restore() {
  ensure_installed
  ensure_dirs
  backup_list
  read -rp "输入要恢复的备份文件名(例如 backup-xxxx.tar.gz): " f
  local bk="$APP_DIR/backups/$f"
  [[ ! -f "$bk" ]] && err "不存在：$bk" && exit 1

  warn "即将恢复备份：$bk（仅恢复本项目目录与本项目生成的 nginx 配置文件）"
  read -rp "确认继续? 输入 yes: " yes
  [[ "$yes" != "yes" ]] && exit 0

  # 恢复 APP_DIR
  tar -xzf "$bk" -C / --overwrite

  # 恢复本项目 nginx 配置（不会覆盖其他站点）
  if [[ -d "/nginx" ]]; then
    mkdir -p "$NGINX_DIR_AVAILABLE" "$NGINX_DIR_ENABLED"
    cp -a /nginx/sites-available/* "$NGINX_DIR_AVAILABLE/" 2>/dev/null || true
    cp -a /nginx/sites-enabled/* "$NGINX_DIR_ENABLED/" 2>/dev/null || true
    rm -rf /nginx 2>/dev/null || true
    nginx -t && systemctl reload nginx || true
  fi

  compose_up
  log "恢复完成"
}

# -------------------------- Uninstall (safe) --------------------------

uninstall_all() {
  warn "即将卸载 ${APP_NAME}（仅移除本项目容器/数据/本项目生成的 Nginx 配置/命令，不碰其他站点）"
  read -rp "确认卸载? 输入 yes: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && exit 0

  if [[ -f "$COMPOSE_FILE" ]]; then
    compose_down_volumes
  fi

  # 删除本项目 nginx 配置（按记录域名）
  if nginx_is_installed; then
    while read -r d; do
      [[ -z "$d" ]] && continue
      rm -f "$(nginx_site_path_for_domain "$d")" "$(nginx_link_path_for_domain "$d")" 2>/dev/null || true
      # 可选：移除 certbot 证书（只移除该域名）
      if has_cmd certbot; then
        certbot delete --cert-name "$d" --non-interactive >/dev/null 2>&1 || true
      fi
    done < <(list_recorded_domains)

    nginx -t && systemctl reload nginx || true
  fi

  rm -rf "$APP_DIR"
  rm -f "$INSTALL_CMD_PATH" 2>/dev/null || true

  log "卸载完成"
}

# -------------------------- Install as command --------------------------

install_as_command() {
  local target="$INSTALL_CMD_PATH"
  local self
  self="$(readlink -f "$0" 2>/dev/null || true)"

  # 1) 本地文件运行：直接复制自身
  if [[ -n "$self" && -f "$self" ]]; then
    install -m 0755 "$self" "$target"
    log "已安装系统命令：$target"
    log "以后直接输入：decotv"
    return 0
  fi

  # 2) 管道运行（curl|bash）：自动从 RAW_URL 下载并安装
  warn "检测到可能是通过管道运行（无法定位脚本本地路径）。"
  warn "将自动从仓库下载最新版并安装为系统命令：$target"
  echo "  来源: $RAW_URL"
  read -rp "确认继续安装为系统命令? (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 0

  install_pkg ca-certificates curl >/dev/null 2>&1 || true
  if ! has_cmd curl; then
    err "缺少 curl，无法下载脚本。请先安装 curl 后重试。"
    return 1
  fi

  local tmp="/tmp/decotv.$$.sh"
  if ! curl -fsSL "$RAW_URL" -o "$tmp"; then
    err "下载失败：$RAW_URL"
    return 1
  fi
  chmod 0755 "$tmp"
  mv -f "$tmp" "$target"
  log "已安装系统命令：$target"
  log "以后直接输入：decotv"
}



# -------------------------- Menu --------------------------

menu() {
  need_root
  while true; do
    clear || true
    echo "============================================================"
    echo " DecoTV 快捷启动面板（Nginx+HTTPS+备份/恢复）"
    echo "============================================================"
    echo " 1) 安装/部署"
    echo " 2) 信息"
    echo " 3) 状态"
    echo " 4) 启动"
    echo " 5) 停止"
    echo " 6) 重启"
    echo " 7) 查看日志 (tail -f)"
    echo " 8) 更新镜像"
    echo " 9) 启用 HTTPS/证书（Nginx+Certbot）"
    echo "10) 创建备份"
    echo "11) 备份列表"
    echo "12) 恢复备份"
    echo "13) 安装为系统命令(decotv)"
    echo "14) 彻底卸载（含数据/配置）"
    echo " 0) 退出"
    echo "------------------------------------------------------------"
    read -rp "请选择: " n
    case "$n" in
      1)
        install_docker
        install_compose
        write_compose
        compose_up
        log "部署完成：请访问 http://服务器IP:${PORT} 或通过 Nginx 反代使用域名"
        pause
        ;;
      2) show_info; pause ;;
      3) status; pause ;;
      4) start_app; pause ;;
      5) stop_app; pause ;;
      6) restart_app; pause ;;
      7) logs_app ;;
      8) update_image; pause ;;
      9) https_enable_flow; pause ;;
      10) backup_create; pause ;;
      11) backup_list; pause ;;
      12) backup_restore; pause ;;
      13) install_as_command; pause ;;
      14) uninstall_all; pause ;;
      0) exit 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  bash decotv.sh              # 进入交互菜单
  decotv                      #（安装为命令后）进入交互菜单

子命令：
  decotv menu|install|info|status|start|stop|restart|logs|update|https|backup|backups|restore|cmd|uninstall

环境变量(可选)：
  APP_DIR PORT IMAGE KVROCKS_IMAGE

说明：
  - 本脚本为“安全共存版”：不会删除 /etc/nginx/sites-enabled/default
  - 仅新增自己的站点配置：/etc/nginx/sites-available/decotv-<domain>.conf
  - 仅移除自己生成的配置与证书，不影响其他站点
EOF
}

# -------------------------- CLI entry --------------------------

need_root

cmd="${1:-}"
case "$cmd" in
  ""|"menu") menu ;;
  "install") install_docker; install_compose; write_compose; compose_up ;;
  "info") show_info ;;
  "status") status ;;
  "start") start_app ;;
  "stop") stop_app ;;
  "restart") restart_app ;;
  "logs") logs_app ;;
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
