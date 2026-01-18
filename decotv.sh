#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ==========================================================
# DecoTV · One-click Manager (Docker + optional HTTPS reverse proxy)
# - 部署/更新/状态/日志/卸载/清理
# - 可选：Docker Nginx + acme.sh(standalone) HTTPS 反代
# - 反代：同 Docker 网络直连上游，避免 502（不走 127.0.0.1）
# - 反代状态：显示是否启用 + 绑定域名 + 上游
# - 脚本自更新：从 RAW 拉取覆盖当前脚本
# ==========================================================

APP="DecoTV"
DIR="/opt/decotv"
ENVF="$DIR/.env"
YML="$DIR/docker-compose.yml"

C1="decotv-core"
C2="decotv-kvrocks"
IMG1="ghcr.io/decohererk/decotv:latest"
IMG2="apache/kvrocks:latest"

# 反代：Docker Nginx + acme.sh standalone
NGX_DIR="$DIR/nginx"
NGX_CONF="$NGX_DIR/nginx.conf"
NGX_CERTS="$NGX_DIR/certs"
NGX_C="decotv-nginx"
NGX_IMG="nginx:latest"

# Compose 网络名（强制 name: decotv-network，避免 compose 自动加前缀）
NET="decotv-network"

# 脚本自更新（改成你自己的 raw 地址）
SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/ljp210724/bytv/main/decotv.sh"

# 用于自更新校验（避免下错文件）
DECOTV_SCRIPT_MARK="DECOTV_SCRIPT_MARK_v1"

# ------------------------------
# 基础工具
# ------------------------------
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 运行（sudo -i）"; exit 1; }; }
has() { command -v "$1" >/dev/null 2>&1; }
pm() { has apt-get && echo apt || has dnf && echo dnf || has yum && echo yum || has pacman && echo pacman || echo none; }
pause() { read -r -p "按回车继续..." _ || true; }

installed() { [[ -f "$ENVF" && -f "$YML" ]]; }
compose() { (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }
kv() { grep -E "^$1=" "$ENVF" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

inst_pkgs() {
  local m; m="$(pm)"
  case "$m" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
      ;;
    dnf) dnf install -y "$@" >/dev/null ;;
    yum) yum install -y "$@" >/dev/null ;;
    pacman) pacman -Sy --noconfirm "$@" >/dev/null ;;
    *) echo "不支持的包管理器，请手动安装：$*"; exit 1 ;;
  esac
}

ensure() {
  # curl/ca/ss/socat/getent
  has curl || inst_pkgs curl ca-certificates
  has ss || inst_pkgs iproute2 || true
  has getent || inst_pkgs libc-bin || true
  has socat || inst_pkgs socat || true

  if ! has docker; then
    curl -fsSL https://get.docker.com | sh
  fi
  has systemctl && systemctl enable --now docker >/dev/null 2>&1 || true

  docker compose version >/dev/null 2>&1 || inst_pkgs docker-compose-plugin || true
  docker compose version >/dev/null 2>&1 || { echo "Docker Compose 不可用，请手动安装 compose 插件"; exit 1; }
}

get_public_ip() {
  curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

port_in_use() {
  local p="$1"
  has ss || return 1
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

pick_port() {
  local p="${1:-3000}"
  if [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1 && p<=65535)) && ! port_in_use "$p"; then
    echo "$p"; return
  fi
  for x in 3000 3001 3030 3080 3100 3200 8080 18080; do
    ! port_in_use "$x" && { echo "$x"; return; }
  done
  while :; do
    local x
    x="$(shuf -i 20000-60000 -n 1 2>/dev/null || echo 3000)"
    ! port_in_use "$x" && { echo "$x"; return; }
  done
}

# ------------------------------
# 反代状态（写入 .env）
# ------------------------------
rp_domain() { kv RP_DOMAIN; }
rp_upstream() { kv RP_UPSTREAM; }   # 例如 decotv-core:3000
rp_enabled() { [[ -n "$(rp_domain)" ]]; }

# 自动探测 core 容器暴露端口（优先 ExposedPorts，否则 3000）
detect_core_internal_port() {
  local p
  p="$(docker inspect -f '{{range $k,$v := .Config.ExposedPorts}}{{println $k}}{{end}}' "$C1" 2>/dev/null \
        | head -n1 | awk -F/ '{print $1}' | tr -d '\r' || true)"
  [[ -n "${p:-}" ]] && { echo "$p"; return; }
  echo "3000"
}

get_access_url() {
  if rp_enabled; then
    echo "https://$(rp_domain)"
    return
  fi
  local host p
  host="$(get_public_ip || true)"; [[ -z "${host:-}" ]] && host="<服务器IP>"
  p="$(kv APP_PORT)"
  echo "http://${host}:${p:-?}"
}

running_state() {
  installed || { echo "未安装"; return; }
  local n
  n="$(compose ps --status running 2>/dev/null | awk 'NR>1{print $1}' | wc -l | tr -d ' ')"
  [[ "$n" == "2" ]] && echo "运行中" || echo "未完全运行"
}

c_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "不存在"; }
c_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}无健康检查{{end}}' "$1" 2>/dev/null || echo "-"; }
c_ports() { docker port "$1" 2>/dev/null | head -n1 | tr -d '\r' || echo "-"; }

status_summary() {
  echo "------------------------------"
  echo "服务状态（紧凑版）"
  echo "------------------------------"
  printf "%-14s | %-8s | %s\n" "容器" "状态" "端口/健康"
  echo "------------------------------"
  printf "%-14s | %-8s | %s\n" "$C1" "$(c_state "$C1")" "$(c_ports "$C1")"
  printf "%-14s | %-8s | %s\n" "$C2" "$(c_state "$C2")" "$(c_health "$C2")"
  printf "%-14s | %-8s | %s\n" "$NGX_C" "$(c_state "$NGX_C")" "$(c_ports "$NGX_C")"
  echo "------------------------------"

  if rp_enabled; then
    echo "域名反代：已启用"
    echo "绑定域名：$(rp_domain)"
    echo "上游：$(rp_upstream)"
  else
    echo "域名反代：未启用"
  fi
  echo "访问地址：$(get_access_url)"
}

# ------------------------------
# 写配置
# ------------------------------
write_cfg() {
  local port="$1" user="$2" pass="$3"
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$user
PASSWORD=$pass
APP_PORT=$port
SCRIPT_URL=$SCRIPT_URL_DEFAULT
EOF

  cat >"$YML" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: unless-stopped
    ports: ["${APP_PORT}:3000"]
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    networks: [decotv-network]
    depends_on: [decotv-kvrocks]

  decotv-kvrocks:
    image: apache/kvrocks:latest
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes: [kvrocks-data:/var/lib/kvrocks]
    networks: [decotv-network]

networks:
  decotv-network:
    name: decotv-network
    driver: bridge

volumes:
  kvrocks-data: {}
EOF
}

deploy_done_output() {
  local user pass
  user="$(kv USERNAME)"; pass="$(kv PASSWORD)"
  echo
  echo "=============================="
  echo " DecoTV 部署完成"
  echo "=============================="
  echo "访问地址：$(get_access_url)"
  if rp_enabled; then
    echo "域名反代：https://$(rp_domain)"
    echo "上游：$(rp_upstream)"
  else
    echo "端口映射：$(kv APP_PORT):3000"
  fi
  echo "账号：${user}"
  echo "密码：${pass}"
  echo
  echo "常用命令："
  echo "  核心日志：docker logs -f --tail=200 ${C1}"
  echo "  反代日志：docker logs -f --tail=200 ${NGX_C}"
  echo
}

# ------------------------------
# HTTPS 反代
# ------------------------------
domain_resolve_ip() {
  local d="$1"
  getent ahosts "$d" 2>/dev/null | awk '{print $1}' | head -n1 || true
}

ensure_acme() {
  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1 || true
  fi
  [[ -x "${HOME}/.acme.sh/acme.sh" ]] || { echo "acme.sh 安装失败，请检查网络后重试"; return 1; }

  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true
}

acme_cert_dir() { local domain="$1"; echo "${HOME}/.acme.sh/${domain}_ecc"; }
has_local_cert() {
  local domain="$1" cd
  cd="$(acme_cert_dir "$domain")"
  [[ -s "${cd}/fullchain.cer" && -s "${cd}/${domain}.key" ]]
}

issue_cert() {
  local domain="$1" force="${2:-0}"
  local acme="${HOME}/.acme.sh/acme.sh"
  if [[ "$force" == "1" ]]; then
    "$acme" --issue -d "$domain" --standalone --server letsencrypt --force
  else
    "$acme" --issue -d "$domain" --standalone --server letsencrypt
  fi
}

install_cert() {
  local domain="$1"
  local acme="${HOME}/.acme.sh/acme.sh"
  mkdir -p "$NGX_DIR" "$NGX_CERTS"
  "$acme" --installcert -d "$domain" \
    --key-file "$NGX_CERTS/key.pem" \
    --fullchain-file "$NGX_CERTS/cert.pem" >/dev/null
}

# ✅ 关键：nginx 在 docker 里，必须走同网络：proxy_pass decotv-core:端口
write_nginx_conf() {
  local domain="$1" core_port="$2"
  mkdir -p "$NGX_DIR" "$NGX_CERTS"
  cat >"$NGX_CONF" <<EOF
events { worker_connections 1024; }
http {
  client_max_body_size 1000m;

  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
  }

  server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;

    location / {
      proxy_pass http://${C1}:${core_port};
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
    }
  }
}
EOF
}

ensure_net() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null 2>&1 || true
}

run_nginx_container() {
  ensure_net
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true
  docker run -d \
    --name "$NGX_C" \
    --network "$NET" \
    -p 80:80 -p 443:443 \
    -v "$NGX_CONF:/etc/nginx/nginx.conf" \
    -v "$NGX_CERTS:/etc/nginx/certs" \
    "$NGX_IMG" >/dev/null
  docker update --restart=always "$NGX_C" >/dev/null 2>&1 || true
}

# 80/443 被占用时：如果是我们自己的 nginx 容器在占用，则允许继续“重配/续期”
ports_owned_by_our_nginx() {
  [[ "$(c_state "$NGX_C")" == "running" ]] || return 1
  docker port "$NGX_C" 2>/dev/null | grep -qE '0\.0\.0\.0:80->|:::80->' && \
  docker port "$NGX_C" 2>/dev/null | grep -qE '0\.0\.0\.0:443->|:::443->'
}

bind_domain_proxy() {
  installed || { echo "未安装，请先部署"; return; }

  # 端口占用检查：不干预其他服务；若是我们自己的 nginx 占用则继续
  if (port_in_use 80 || port_in_use 443) && ! ports_owned_by_our_nginx; then
    echo "检测到 80/443 已被占用："
    port_in_use 80 && echo " - 80 端口占用（standalone 需要 80）"
    port_in_use 443 && echo " - 443 端口占用（nginx 需要 443）"
    echo "请先释放 80/443 后再绑定域名。"
    return
  fi

  read -r -p "请输入域名（A 记录指向本机公网 IP）：" domain
  [[ -n "${domain:-}" ]] || { echo "域名不能为空"; return; }

  local sip dip
  sip="$(get_public_ip || true)"
  dip="$(domain_resolve_ip "$domain" || true)"
  if [[ -n "${sip:-}" && -n "${dip:-}" && "$sip" != "$dip" ]]; then
    echo "警告：域名解析 IP = ${dip}，本机公网 IP = ${sip}"
    echo "若开启 Cloudflare 橙云代理，请先切灰云再签证书。"
    read -r -p "仍继续？(y/n) [n]：" a
    [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  fi

  ensure_acme || return

  read -r -p "是否强制续期证书？(y/n) [n]：" f
  local force="0"
  [[ "${f:-n}" == "y" ]] && force="1"

  echo "开始申请/续期证书（standalone / Let's Encrypt）：$domain"
  set +e
  issue_cert "$domain" "$force"
  local rc=$?
  set -e

  # 不把 Skipping 当失败：有本地证书就继续 install
  if [[ $rc -ne 0 ]]; then
    if has_local_cert "$domain"; then
      echo "检测到本地已有有效证书（可能是 Skipping），继续安装证书..."
    else
      echo "证书签发失败（且本地无可用证书）。"
      echo "常见原因：80 不通 / 解析未生效 / 橙云代理 / 防火墙拦截"
      return
    fi
  fi

  install_cert "$domain" || { echo "证书安装失败"; return; }

  # 自动探测 core 内部端口
  local core_port upstream
  core_port="$(detect_core_internal_port)"
  upstream="${C1}:${core_port}"

  write_nginx_conf "$domain" "$core_port"
  run_nginx_container

  # 写入反代信息
  sed -i '/^RP_DOMAIN=/d;/^RP_UPSTREAM=/d' "$ENVF" 2>/dev/null || true
  {
    echo "RP_DOMAIN=${domain}"
    echo "RP_UPSTREAM=${upstream}"
  } >>"$ENVF"

  echo
  echo "=============================="
  echo " 域名反代已配置完成"
  echo "=============================="
  echo "访问地址：https://${domain}"
  echo "上游：${upstream}（同网络直连）"
  echo "nginx 容器：${NGX_C}"
  echo
}

# ------------------------------
# 镜像更新说明：不会删除 volume，不会丢用户数据
# ------------------------------
update_images() {
  ensure
  installed || { echo "未安装，请先部署"; return; }
  echo "说明：更新镜像不会删除数据卷（kvrocks-data），用户数据不会丢。"
  compose pull
  compose up -d
  echo "更新完成：$(get_access_url)"
  status_summary
}

# ------------------------------
# 脚本自更新
# ------------------------------
script_path() {
  local p
  p="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  [[ -n "${p:-}" ]] && { echo "$p"; return; }
  echo "$0"
}

update_script_self() {
  ensure
  local url path tmp oldperm
  url="$(kv SCRIPT_URL || true)"
  url="${url:-$SCRIPT_URL_DEFAULT}"
  path="$(script_path)"
  tmp="$(mktemp -t decotv.sh.XXXXXX)"

  echo "当前脚本：$path"
  echo "更新来源：$url"

  if ! curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp"; then
    rm -f "$tmp" || true
    echo "❌ 下载失败：无法连接到更新源"
    return
  fi

  # 校验：shebang + 标记，避免覆盖成别的文件
  if ! head -n1 "$tmp" | grep -qE '^#!/usr/bin/env bash'; then
    rm -f "$tmp" || true
    echo "❌ 校验失败：不是 bash 脚本"
    return
  fi
  if ! grep -q "$DECOTV_SCRIPT_MARK" "$tmp"; then
    rm -f "$tmp" || true
    echo "❌ 校验失败：更新源不是 DecoTV 脚本（标记不匹配）"
    echo "请确认 SCRIPT_URL / 默认 URL 指向正确的脚本 raw"
    return
  fi

  oldperm="$(stat -c '%a' "$path" 2>/dev/null || echo 755)"
  cp -f "$tmp" "$path"
  chmod "$oldperm" "$path" 2>/dev/null || chmod +x "$path" || true
  rm -f "$tmp" || true

  echo "✅ 脚本已更新完成"
  echo "请重新运行：$path"
}

# ------------------------------
# 部署 / 状态 / 日志 / 卸载 / 清理
# ------------------------------
do_deploy() {
  ensure
  if installed; then
    read -r -p "检测到已安装，是否覆盖并重建？(y/n) [n]：" a
    [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  fi

  read -r -p "设置用户名 [admin]：" user; user="${user:-admin}"

  local p1 p2
  while :; do
    read -r -p "设置密码（可见）：" p1
    read -r -p "再次确认（可见）：" p2
    [[ -n "${p1:-}" ]] || { echo "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { echo "两次密码不一致"; continue; }
    break
  done

  read -r -p "外部访问端口 [3000]：" pp; pp="${pp:-3000}"
  local port
  port="$(pick_port "$pp")"
  [[ "$port" != "$pp" ]] && echo "端口 $pp 已占用，自动选用：$port"

  write_cfg "$port" "$user" "$p1"
  compose up -d

  read -r -p "是否绑定域名并配置 HTTPS 反代（占用80/443）？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] && bind_domain_proxy || true

  status_summary
  deploy_done_output
}

show_status() {
  ensure
  installed || { echo "未安装"; return; }
  echo "运行状态：$(running_state)"
  echo "访问地址：$(get_access_url)"
  if rp_enabled; then
    echo "域名反代：已启用（${NGX_C}）"
    echo "绑定域名：$(rp_domain)"
    echo "上游：$(rp_upstream)"
  else
    echo "域名反代：未启用/未运行"
  fi
  status_summary
  echo "账号：$(kv USERNAME)"
  read -r -p "是否显示密码？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] && echo "密码：$(kv PASSWORD)"
}

show_logs() {
  ensure
  installed || { echo "未安装"; return; }
  echo "1) 核心(core)日志"
  echo "2) 数据库(kvrocks)日志"
  echo "3) 反代(nginx)日志"
  echo "0) 返回"
  read -r -p "请选择 [0-3]：" c
  case "${c:-}" in
    1) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$C1" ;;
    2) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$C2" ;;
    3) echo "提示：按 Ctrl+C 退出日志"; docker logs -f --tail=200 "$NGX_C" ;;
    0) return ;;
    *) echo "无效选择" ;;
  esac
}

do_uninstall() {
  ensure
  echo "将执行：停止并删除容器/卷/网络/目录，并尝试删除镜像；最后删除脚本本体。"
  read -r -p "确认卸载？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }

  if installed; then
    (cd "$DIR" && docker compose --env-file "$ENVF" down -v --remove-orphans) || true
  fi
  docker rm -f "$C1" >/dev/null 2>&1 || true
  docker rm -f "$C2" >/dev/null 2>&1 || true
  docker rm -f "$NGX_C" >/dev/null 2>&1 || true

  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm kvrocks-data >/dev/null 2>&1 || true

  docker rmi -f "$IMG1" >/dev/null 2>&1 || true
  docker rmi -f "$IMG2" >/dev/null 2>&1 || true
  docker rmi -f "$NGX_IMG" >/dev/null 2>&1 || true

  rm -rf "$DIR" || true

  echo "卸载完成，即将删除脚本本体并退出。"
  ( sleep 1; rm -f "$(script_path)" >/dev/null 2>&1 || true ) &
  exit 0
}

do_clean() {
  ensure
  echo "仅清理未使用资源：悬空镜像/未使用网络/未使用卷（不会删除正在使用的卷）"
  read -r -p "确认清理？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  docker system prune -f >/dev/null 2>&1 || true
  docker volume prune -f >/dev/null 2>&1 || true
  echo "清理完成"
}

# ------------------------------
# UI
# ------------------------------
menu() {
  clear 2>/dev/null || true
  echo "$DECOTV_SCRIPT_MARK"
  echo "=============================="
  echo " ${APP} · 交互式管理面板"
  echo "=============================="
  echo "当前状态：$(running_state) ｜ 访问：$(get_access_url)"
  if rp_enabled; then
    echo "域名反代：已启用（${NGX_C}）｜ 域名：$(rp_domain) ｜ 上游：$(rp_upstream)"
  else
    echo "域名反代：未启用"
  fi
  echo
  echo "1) 部署 / 重装"
  echo "2) 更新（拉取最新镜像，不丢数据）"
  echo "3) 状态（查看信息）"
  echo "4) 日志（实时跟踪）"
  echo "5) 卸载（彻底删除）"
  echo "6) 清理（Docker 垃圾清理）"
  echo "7) 域名反代（配置/重配 HTTPS 反代）"
  echo "8) 更新脚本（拉取最新脚本本体）"
  echo "0) 退出"
  echo
}

main() {
  need_root
  while :; do
    menu
    read -r -p "请选择 [0-8]：" c
    case "${c:-}" in
      1) do_deploy; pause ;;
      2) update_images; pause ;;
      3) show_status; pause ;;
      4) show_logs ;;
      5) do_uninstall ;;
      6) do_clean; pause ;;
      7) bind_domain_proxy; pause ;;
      8) update_script_self; pause ;;
      0) exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

main "$@"
