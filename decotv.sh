#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP="decotv"
STACK_DIR="/opt/decotv"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
ENV_FILE="${STACK_DIR}/.env"

# Our nginx working dir (for backups/record only)
NGX_DIR="/etc/nginx/${APP}"

# iptables chain (isolated)
CHAIN_NAME="DECO_${APP^^}"

# --------------------------
# UI helpers
# --------------------------
color() { local c="$1"; shift; printf "\033[%sm%s\033[0m" "$c" "$*"; }
green(){ color "32" "$*"; }
red(){ color "31" "$*"; }
yellow(){ color "33" "$*"; }
blue(){ color "36" "$*"; }
hr(){ printf "%s\n" "----------------------------------------------"; }
pause(){ read -r -p "按回车继续..." _; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_os_pkg_mgr() {
  if cmd_exists apt-get; then echo "apt"
  elif cmd_exists dnf; then echo "dnf"
  elif cmd_exists yum; then echo "yum"
  elif cmd_exists apk; then echo "apk"
  elif cmd_exists pacman; then echo "pacman"
  else echo "unknown"
  fi
}

pkg_install() {
  local mgr; mgr="$(detect_os_pkg_mgr)"
  case "$mgr" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *)
      echo "$(red "不支持的包管理器，无法自动安装依赖：$mgr")"
      return 1
      ;;
  esac
}

print_title() {
  clear || true
  echo
  echo "=============================="
  echo " ${APP} · DecoTV Manager"
  echo "=============================="
}

stack_installed() { [[ -f "$COMPOSE_FILE" ]] && [[ -d "$STACK_DIR" ]]; }

docker_ok() { cmd_exists docker && docker info >/dev/null 2>&1; }

compose_cmd() {
  if docker_ok && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif cmd_exists docker-compose; then
    echo "docker-compose"
  else
    echo ""
  fi
}

nginx_ok() { cmd_exists nginx; }

get_public_ip() {
  local ip=""
  ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || true)"
  echo "${ip}"
}

get_listen_port_from_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" >/dev/null 2>&1 || true
  fi
  echo "${HOST_PORT:-3000}"
}

get_domain_from_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" >/dev/null 2>&1 || true
  fi
  echo "${DOMAIN:-}"
}

mask_pw() {
  local s="${1:-}"
  if [[ -z "$s" ]]; then echo ""; return 0; fi
  if ((${#s}<=2)); then echo "**"; return 0; fi
  echo "${s:0:1}***${s: -1}"
}

ensure_basic_deps() {
  echo "$(blue "检测依赖...")"
  local need=()
  cmd_exists curl || need+=(curl)
  cmd_exists jq || need+=(jq)
  cmd_exists openssl || need+=(openssl)
  cmd_exists iptables || need+=(iptables)
  cmd_exists git || need+=(git)

  if ((${#need[@]})); then
    echo "$(yellow "缺少依赖：${need[*]}")"
    echo "$(blue "正在安装依赖（仅安装必要组件，不改动其他服务）...")"
    pkg_install "${need[@]}"
  else
    echo "$(green "依赖齐全")"
  fi
}

install_docker_if_needed() {
  if docker_ok; then
    echo "$(green "Docker 已可用")"
    return 0
  fi

  echo "$(yellow "未检测到可用 Docker，开始安装 Docker（仅安装 Docker，不改动其他服务）...")"
  local mgr; mgr="$(detect_os_pkg_mgr)"
  case "$mgr" in
    apt)
      pkg_install ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
        $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker >/dev/null 2>&1 || true
      ;;
    dnf|yum)
      pkg_install yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1 || true
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker >/dev/null 2>&1 || true
      ;;
    apk)
      pkg_install docker docker-cli docker-compose
      rc-update add docker >/dev/null 2>&1 || true
      service docker start >/dev/null 2>&1 || true
      ;;
    pacman)
      pkg_install docker docker-compose
      systemctl enable --now docker >/dev/null 2>&1 || true
      ;;
    *)
      echo "$(red "无法自动安装 Docker：不支持的系统/包管理器")"
      return 1
      ;;
  esac

  docker_ok || { echo "$(red "Docker 安装后仍不可用，请检查 docker 服务状态")"; return 1; }
  echo "$(green "Docker 安装完成")"
}

ensure_compose() {
  local cc; cc="$(compose_cmd)"
  if [[ -z "$cc" ]]; then
    echo "$(red "未检测到 docker compose / docker-compose")"
    return 1
  fi
  echo "$(green "Compose 可用：$cc")"
}

write_compose_and_env() {
  mkdir -p "$STACK_DIR"
  local host_port="$1" username="$2" password="$3" domain="${4:-}"
  cat >"$ENV_FILE" <<EOF
# Generated by decotv.sh
HOST_PORT=${host_port}
USERNAME=${username}
PASSWORD=${password}
DOMAIN=${domain}
STORAGE=kvrocks
EOF

  cat >"$COMPOSE_FILE" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: on-failure
    ports:
      - '${HOST_PORT}:3000'
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks:
      - decotv-network
    depends_on:
      - decotv-kvrocks

  decotv-kvrocks:
    image: apache/kvrocks
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

compose_up() {
  local cc; cc="$(compose_cmd)"; [[ -n "$cc" ]] || return 1
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
  (cd "$STACK_DIR" && $cc -f "$COMPOSE_FILE" up -d)
}

compose_pull_up() {
  local cc; cc="$(compose_cmd)"; [[ -n "$cc" ]] || return 1
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
  (cd "$STACK_DIR" && $cc -f "$COMPOSE_FILE" pull && $cc -f "$COMPOSE_FILE" up -d)
}

compose_down() {
  local cc; cc="$(compose_cmd)"; [[ -n "$cc" ]] || return 1
  [[ -f "$ENV_FILE" ]] && { set -a; # shellcheck disable=SC1090
    source "$ENV_FILE" || true; set +a; }
  (cd "$STACK_DIR" && $cc -f "$COMPOSE_FILE" down) || true
}

# --------------------------
# iptables (isolated chain)
# --------------------------
iptables_ensure_chain() {
  iptables -S "$CHAIN_NAME" >/dev/null 2>&1 || iptables -N "$CHAIN_NAME"
  if ! iptables -C INPUT -j "$CHAIN_NAME" >/dev/null 2>&1; then
    iptables -I INPUT 1 -j "$CHAIN_NAME"
  fi
}
iptables_delete_chain() {
  iptables -D INPUT -j "$CHAIN_NAME" >/dev/null 2>&1 || true
  iptables -F "$CHAIN_NAME" >/dev/null 2>&1 || true
  iptables -X "$CHAIN_NAME" >/dev/null 2>&1 || true
}
iptables_allow_ip_port() {
  local ip="$1" port="$2"
  iptables_ensure_chain
  iptables -C "$CHAIN_NAME" -p tcp -s "$ip" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
    iptables -A "$CHAIN_NAME" -p tcp -s "$ip" --dport "$port" -j ACCEPT
}
iptables_block_ip_port() {
  local ip="$1" port="$2"
  iptables_ensure_chain
  iptables -C "$CHAIN_NAME" -p tcp -s "$ip" --dport "$port" -j DROP >/dev/null 2>&1 || \
    iptables -A "$CHAIN_NAME" -p tcp -s "$ip" --dport "$port" -j DROP
}
iptables_set_default_drop_for_port() {
  local port="$1"
  iptables_ensure_chain
  iptables -C "$CHAIN_NAME" -p tcp --dport "$port" -j DROP >/dev/null 2>&1 || \
    iptables -A "$CHAIN_NAME" -p tcp --dport "$port" -j DROP
}
iptables_show() {
  if iptables -S "$CHAIN_NAME" >/dev/null 2>&1; then iptables -S "$CHAIN_NAME"; else echo "(no rules)"; fi
}

# --------------------------
# Nginx (TechLion-style: guarantee loaded)
# Key: write into the REAL include dir (conf.d OR sites-enabled)
# --------------------------
detect_nginx_include_dir() {
  # Prefer what nginx actually includes
  local t
  t="$(nginx -T 2>/dev/null || true)"

  if echo "$t" | grep -qE 'include\s+/etc/nginx/sites-enabled/\*'; then
    echo "/etc/nginx/sites-enabled"; return 0
  fi
  if echo "$t" | grep -qE 'include\s+/etc/nginx/conf\.d/\*'; then
    echo "/etc/nginx/conf.d"; return 0
  fi

  # Fallback to existing dirs
  [[ -d /etc/nginx/sites-enabled ]] && { echo "/etc/nginx/sites-enabled"; return 0; }
  [[ -d /etc/nginx/conf.d ]] && { echo "/etc/nginx/conf.d"; return 0; }

  echo ""
  return 1
}

nginx_reload_safe() {
  nginx -t >/dev/null
  if cmd_exists systemctl && systemctl is-active nginx >/dev/null 2>&1; then
    systemctl reload nginx
  else
    nginx -s reload >/dev/null 2>&1 || true
  fi
}

nginx_write_site_conf_loaded() {
  local domain="$1" upstream_port="$2" listen_port="${3:-80}"

  local inc_dir; inc_dir="$(detect_nginx_include_dir)" || true
  if [[ -z "$inc_dir" ]]; then
    echo "$(red "未找到 Nginx include 目录（conf.d / sites-enabled），无法保证配置生效")"
    return 1
  fi

  mkdir -p "$NGX_DIR"

  # keep a copy under our dir for record/backup
  local backup_conf="${NGX_DIR}/${APP}_${domain}.conf"

  cat >"$backup_conf" <<EOF
# Generated by decotv.sh
# TechLion-style: a standalone server block for this app only.
server {
  listen ${listen_port};
  server_name ${domain};

  client_max_body_size 50m;

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

  # IMPORTANT: write into the REAL include dir to guarantee nginx loads it
  local live_conf="${inc_dir}/${APP}_${domain}.conf"
  cp -f "$backup_conf" "$live_conf"

  nginx_reload_safe

  # Quick local match test (this is the exact thing you used to prove reset)
  # If it still resets, it means your nginx has special rules beyond "not loaded".
  local out
  out="$(curl -sSiv -H "Host: ${domain}" "http://127.0.0.1:${listen_port}/" 2>&1 | head -n 12 || true)"
  if echo "$out" | grep -qi "Connection reset by peer"; then
    echo "$(yellow "警告：本机对该域名仍出现 reset。")"
    echo "$(yellow "这通常说明你的 Nginx 有“强接管 default 规则/安全模板/stream 规则”，需要进一步定位哪段配置在 reset。")"
    echo
    echo "$out"
  fi

  echo "$(green "Nginx 配置已写入并确保被加载：${live_conf}")"
  return 0
}

nginx_remove_site_conf_loaded() {
  local domain="$1"
  local inc_dir; inc_dir="$(detect_nginx_include_dir)" || true
  [[ -n "$inc_dir" ]] && rm -f "${inc_dir}/${APP}_${domain}.conf" >/dev/null 2>&1 || true
  rm -f "${NGX_DIR}/${APP}_${domain}.conf" >/dev/null 2>&1 || true
  if nginx_ok; then nginx_reload_safe || true; fi
}

# --------------------------
# actions
# --------------------------
action_install() {
  print_title
  echo "$(blue "${APP} 未安装 -> 安装")"
  hr

  ensure_basic_deps
  install_docker_if_needed
  ensure_compose

  local host_port username password domain
  read -r -p "设置访问端口（默认 3000，回车使用默认）： " host_port
  host_port="${host_port:-3000}"

  read -r -p "设置后台用户名（默认 admin，回车使用默认）： " username
  username="${username:-admin}"

  while true; do
    read -r -s -p "设置后台密码（必填，输入后回车）： " password
    echo
    [[ -n "$password" ]] && break
    echo "$(yellow "密码不能为空")"
  done

  read -r -p "绑定域名（可选，回车跳过）： " domain
  domain="${domain:-}"

  echo
  echo "$(blue "写入 compose 配置...")"
  write_compose_and_env "$host_port" "$username" "$password" "$domain"

  echo "$(blue "启动容器...")"
  compose_up

  # If domain provided, do techlion-style nginx add (must be loaded)
  if [[ -n "$domain" ]]; then
    if ! nginx_ok; then
      echo "$(yellow "未检测到 nginx")"
      read -r -p "是否安装 nginx？(y/N): " yn
      if [[ "${yn:-N}" == "y" || "${yn:-N}" == "Y" ]]; then
        pkg_install nginx
      else
        echo "$(yellow "跳过 nginx 配置，仍可通过 IP:端口访问")"
      fi
    fi

    if nginx_ok; then
      echo "$(blue "写入 Nginx 反代（保证被加载）...")"
      nginx_write_site_conf_loaded "$domain" "$host_port" "80" || true
    fi
  fi

  echo
  echo "$(green "安装完成 ✅")"
  hr

  local ip; ip="$(get_public_ip)"
  local shown_pw; shown_pw="$(mask_pw "$password")"

  [[ -n "$domain" ]] && echo "绑定域名：$(green "$domain")"
  echo "用户名：$(green "$username")"
  echo "密码：$(green "$shown_pw")"

  if [[ -n "$domain" ]]; then
    echo "域名访问：$(green "http://${domain}/")"
  fi

  if [[ -n "$ip" ]]; then
    echo "IP访问：$(green "http://${ip}:${host_port}/")"
  else
    echo "IP访问：$(green "http://<服务器IP>:${host_port}/")"
  fi

  pause
}

action_update() {
  print_title
  echo "$(blue "${APP} -> 更新")"
  hr

  if ! stack_installed; then
    echo "$(red "未检测到安装：${STACK_DIR}")"
    pause
    return 0
  fi

  ensure_basic_deps
  install_docker_if_needed
  ensure_compose

  echo "$(blue "拉取最新镜像并重启容器...")"
  compose_pull_up

  echo "$(green "更新完成 ✅")"
  pause
}

action_uninstall() {
  print_title
  echo "$(blue "${APP} -> 卸载")"
  hr

  if ! stack_installed; then
    echo "$(yellow "未检测到安装，无需卸载")"
    pause
    return 0
  fi

  local domain; domain="$(get_domain_from_env || true)"

  read -r -p "确认卸载（会停止并删除容器，删除 ${STACK_DIR}）？(y/N): " yn
  if [[ "${yn:-N}" != "y" && "${yn:-N}" != "Y" ]]; then
    echo "已取消"
    pause
    return 0
  fi

  echo "$(blue "停止并删除容器...")"
  compose_down

  if [[ -n "$domain" ]] && nginx_ok; then
    echo "$(blue "清理 Nginx 配置（仅本项目）...")"
    nginx_remove_site_conf_loaded "$domain" || true
  fi

  echo "$(blue "清理 iptables 规则（仅清理本脚本创建的链）...")"
  iptables_delete_chain || true

  echo "$(blue "删除目录：${STACK_DIR}")"
  rm -rf "$STACK_DIR"

  echo "$(green "卸载完成 ✅")"
  pause
}

action_add_domain() {
  print_title
  echo "$(blue "添加域名访问（Nginx 反代，保证生效）")"
  hr

  if ! stack_installed; then
    echo "$(red "请先安装 ${APP}")"
    pause
    return 0
  fi

  ensure_basic_deps

  if ! nginx_ok; then
    echo "$(yellow "未检测到 nginx")"
    read -r -p "是否安装 nginx？(y/N): " yn
    if [[ "${yn:-N}" == "y" || "${yn:-N}" == "Y" ]]; then
      pkg_install nginx
    else
      echo "已取消"
      pause
      return 0
    fi
  fi

  local domain upstream_port
  upstream_port="$(get_listen_port_from_env)"

  read -r -p "请输入域名（例如 tv.example.com）： " domain
  [[ -n "$domain" ]] || { echo "$(red "域名不能为空")"; pause; return 0; }

  echo "$(blue "写入 Nginx 配置到 include 目录并 reload...")"
  nginx_write_site_conf_loaded "$domain" "$upstream_port" "80"

  # persist DOMAIN
  if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^DOMAIN=' "$ENV_FILE"; then
      sed -i "s|^DOMAIN=.*|DOMAIN=${domain}|g" "$ENV_FILE"
    else
      echo "DOMAIN=${domain}" >> "$ENV_FILE"
    fi
  fi

  echo
  echo "$(green "已添加域名反代 ✅")"
  echo "访问地址：$(green "http://${domain}/")"
  pause
}

action_del_domain() {
  print_title
  echo "$(blue "删除域名访问（移除 Nginx 反代）")"
  hr

  ensure_basic_deps

  if ! nginx_ok; then
    echo "$(yellow "nginx 未安装，无需删除反代")"
    pause
    return 0
  fi

  local domain
  domain="$(get_domain_from_env || true)"
  if [[ -z "$domain" ]]; then
    read -r -p "未在配置中找到域名，请手动输入要删除的域名： " domain
  else
    echo "当前记录域名：$(green "$domain")"
    read -r -p "回车确认删除该域名反代，或输入其他域名： " d2
    domain="${d2:-$domain}"
  fi

  [[ -n "$domain" ]] || { echo "$(red "域名不能为空")"; pause; return 0; }

  echo "$(blue "删除 Nginx 配置并 reload...")"
  nginx_remove_site_conf_loaded "$domain" || true

  if [[ -f "$ENV_FILE" ]] && grep -q '^DOMAIN=' "$ENV_FILE"; then
    sed -i "s|^DOMAIN=.*|DOMAIN=|g" "$ENV_FILE"
  fi

  echo "$(green "已删除域名反代 ✅")"
  pause
}

action_allow_ip_port() {
  print_title
  echo "$(blue "允许 IP + 端口访问（iptables）")"
  hr

  ensure_basic_deps

  local ip port
  read -r -p "请输入允许的 IP（例如 1.2.3.4）： " ip
  [[ -n "$ip" ]] || { echo "$(red "IP 不能为空")"; pause; return 0; }

  port="$(get_listen_port_from_env)"
  read -r -p "端口（默认 ${port}，回车使用默认）： " p2
  port="${p2:-$port}"

  iptables_allow_ip_port "$ip" "$port"
  echo "$(green "已允许：${ip} -> tcp/${port}")"
  echo
  echo "$(yellow "当前规则：")"
  iptables_show
  pause
}

action_block_ip_port() {
  print_title
  echo "$(blue "阻止 IP + 端口访问（iptables）")"
  hr

  ensure_basic_deps

  local ip port mode
  port="$(get_listen_port_from_env)"
  echo "1) 阻止某个 IP 访问端口"
  echo "2) 仅允许白名单（把端口默认 DROP，再用“允许”添加白名单）"
  read -r -p "选择 (1/2)： " mode
  mode="${mode:-1}"

  case "$mode" in
    1)
      read -r -p "请输入要阻止的 IP（例如 1.2.3.4）： " ip
      [[ -n "$ip" ]] || { echo "$(red "IP 不能为空")"; pause; return 0; }
      read -r -p "端口（默认 ${port}，回车使用默认）： " p2
      port="${p2:-$port}"
      iptables_block_ip_port "$ip" "$port"
      echo "$(green "已阻止：${ip} -> tcp/${port}")"
      ;;
    2)
      read -r -p "端口（默认 ${port}，回车使用默认）： " p2
      port="${p2:-$port}"
      iptables_set_default_drop_for_port "$port"
      echo "$(green "已设置：tcp/${port} 默认 DROP（请用“允许 IP+端口访问”添加白名单）")"
      ;;
    *)
      echo "已取消"
      pause
      return 0
      ;;
  esac

  echo
  echo "$(yellow "当前规则：")"
  iptables_show
  pause
}

main_menu() {
  while true; do
    print_title

    local state port domain
    if stack_installed; then state="$(green "已安装")"; else state="$(yellow "未安装")"; fi
    port="$(get_listen_port_from_env || true)"
    domain="$(get_domain_from_env || true)"

    echo "$(green "${APP}") ${state}"
    echo "${APP} Docker 镜像：ghcr.io/decohererk/decotv:latest"
    [[ -n "$domain" ]] && echo "已绑定域名：$(green "$domain")"
    echo "服务端口：$(green "${port}")"
    echo "项目目录：${STACK_DIR}"
    hr
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 卸载"
    echo
    echo "5. 添加域名访问（Nginx 反代，保证生效）"
    echo "6. 删除域名访问（Nginx 反代）"
    echo "7. 允许 IP+端口 访问（iptables）"
    echo "8. 阻止 IP+端口 访问（iptables）"
    hr
    echo "0. 退出"
    echo
    read -r -p "请输入你的选择: " choice

    case "${choice:-}" in
      1) action_install ;;
      2) action_update ;;
      3) action_uninstall ;;
      5) action_add_domain ;;
      6) action_del_domain ;;
      7) action_allow_ip_port ;;
      8) action_block_ip_port ;;
      0) exit 0 ;;
      *) echo "$(yellow "无效选择")"; pause ;;
    esac
  done
}

if ! is_root; then
  echo "$(red "请使用 root 运行：sudo bash $0")"
  exit 1
fi

main_menu
