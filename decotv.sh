#!/usr/bin/env bash
set -euo pipefail

APP="DecoTV v3"
BASE="/opt/decotv"
NET="decotv-net"
COMPOSE="$BASE/docker-compose.yml"
ENVF="$BASE/decotv.env"

NGX_CONF="/etc/nginx/conf.d/decotv.conf"            # 传统 Nginx
NGX_SITES_AVAIL="/etc/nginx/sites-available/decotv" # Debian/Ubuntu Nginx（可选）
NGX_SITES_EN="/etc/nginx/sites-enabled/decotv"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [[ ${EUID:-999} -eq 0 ]] || die "请用 root 运行"; }
pause() { read -rp "按 Enter 继续..."; }

has() { command -v "$1" &>/dev/null; }

# ---------------- OS ----------------
detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统（缺少 /etc/os-release）"
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "仅支持 Debian/Ubuntu（当前：${ID:-unknown}）" ;;
  esac
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

# ---------------- Docker/Compose ----------------
dc() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  elif has docker-compose; then
    docker-compose "$@"
  else
    die "未找到 docker compose / docker-compose"
  fi
}

ensure_base() {
  detect_os
  warn "检查并安装基础依赖..."
  apt_install ca-certificates curl jq dnsutils iproute2 >/dev/null
  ok "基础依赖就绪"

  if ! has docker; then
    warn "未检测到 Docker，开始安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
    ok "Docker 安装完成"
  else
    ok "Docker 已存在"
  fi

  if ! docker compose version &>/dev/null; then
    warn "未检测到 docker compose 插件，尝试安装 docker-compose-plugin..."
    if apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      ok "docker compose 插件安装完成"
    else
      warn "docker-compose-plugin 安装失败，尝试安装 docker-compose 二进制..."
      if ! has docker-compose; then
        local ver="v2.25.0"
        curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)" \
          -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        ok "docker-compose 安装完成（${ver}）"
      else
        ok "docker-compose 已存在"
      fi
    fi
  else
    ok "docker compose 插件已存在"
  fi
}

# ---------------- Helpers ----------------
is_listen() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(:|\\[::\\]:)$1\$"; }

listen_proc_line() {
  # prints one line of ss -ltnp matching port
  ss -ltnp 2>/dev/null | awk -v p=":$1" 'NR>1 && $4 ~ p"$" {print; exit}' || true
}

port_owner() {
  local line; line="$(listen_proc_line "$1")"
  [[ -z "$line" ]] && echo "" && return 0
  # crude detect
  echo "$line" | grep -qi nginx && echo "nginx" && return 0
  echo "$line" | grep -qi caddy && echo "caddy" && return 0
  echo "$line" | grep -qi apache && echo "apache" && return 0
  echo "$line" | grep -qi httpd && echo "apache" && return 0
  echo "$line" | grep -qi openresty && echo "openresty" && return 0
  echo "$line" | grep -qi docker && echo "docker" && return 0
  echo "other"
}

pick_free_port() {
  local cands=(80 8080 8880 10080 18080)
  for p in "${cands[@]}"; do
    if ! is_listen "$p"; then echo "$p"; return 0; fi
  done
  while true; do
    local p=$(( (RANDOM % 40001) + 20000 ))
    if ! is_listen "$p"; then echo "$p"; return 0; fi
  done
}

# ---------------- Cloudflare DNS ----------------
cf_ip() { curl -fsSL ipv4.icanhazip.com | tr -d '\n'; }

cf_api() {
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
  ip="$(cf_ip)"; [[ -n "$ip" ]] || die "获取公网 IPv4 失败"
  zone_id="$(cf_api GET "/zones?name=${CF_ZONE}" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "❌ Cloudflare Zone 不存在或 Token 无权限"
  rid="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${DOMAIN}" | jq -r '.result[0].id // empty')"

  local payload
  payload="$(jq -cn --arg name "$DOMAIN" --arg content "$ip" '{type:"A",name:$name,content:$content,ttl:120,proxied:false}')"

  if [[ -z "$rid" ]]; then
    warn "➕ 创建 DNS A：${DOMAIN} -> ${ip}"
    cf_api POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null
  else
    warn "♻️ 更新 DNS A：${DOMAIN} -> ${ip}"
    cf_api PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" >/dev/null
  fi

  warn "等待 DNS 生效并校验..."
  sleep 4
  local digip
  digip="$(dig +short "$DOMAIN" | tail -n1 | tr -d '\n' || true)"
  if [[ "$digip" != "$ip" ]]; then
    warn "DNS 暂未一致（dig=$digip，本机IP=$ip），可能是传播/缓存。"
    read -rp "是否继续部署？(y/n): " go
    [[ "${go:-n}" == "y" ]] || die "已取消"
  else
    ok "✅ Cloudflare 解析校验通过"
  fi
}

# ---------------- Password input ----------------
read_hidden_or_visible() {
  local prompt="$1" __var="$2" vis="${3:-n}" val
  if [[ "$vis" == "y" ]]; then
    read -rp "$prompt" val
  else
    read -srp "$prompt" val; echo
  fi
  printf -v "$__var" '%s' "$val"
}

read_password_twice() {
  local show="$1" p1 p2
  while true; do
    read_hidden_or_visible "管理员密码: " p1 "$show"
    read_hidden_or_visible "再次输入密码: " p2 "$show"
    [[ -n "$p1" ]] || { warn "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { warn "两次密码不一致"; continue; }
    PASS="$p1"; break
  done
}

# ---------------- Compose/Env ----------------
write_env() {
  mkdir -p "$BASE"
  cat >"$ENVF" <<EOF
DOMAIN=${DOMAIN}
USERNAME=${USER}
PASSWORD=${PASS}
EOF
  chmod 600 "$ENVF" || true
}

write_compose() {
  mkdir -p "$BASE"
  cat >"$COMPOSE" <<EOF
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
}

ensure_network() {
  if ! docker network inspect "$NET" &>/dev/null; then
    docker network create "$NET" >/dev/null
    ok "创建 Docker 网络：$NET"
  else
    ok "Docker 网络已存在：$NET"
  fi
}

# ---------------- Reverse proxy (Lion-style) ----------------
nginx_conf_write() {
  local listen_port="$1"
  local target="http://127.0.0.1:3000"

  # Debian/Ubuntu: prefer sites-available if exists
  if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
    cat >"$NGX_SITES_AVAIL" <<EOF
# ${APP} - non-intrusive reverse proxy (only this file)
server {
  listen ${listen_port};
  server_name ${DOMAIN};

  location / {
    proxy_pass ${target};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
    ln -sf "$NGX_SITES_AVAIL" "$NGX_SITES_EN"
    ok "写入 Nginx 站点：$NGX_SITES_AVAIL"
  else
    cat >"$NGX_CONF" <<EOF
# ${APP} - non-intrusive reverse proxy (only this file)
server {
  listen ${listen_port};
  server_name ${DOMAIN};

  location / {
    proxy_pass ${target};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
    ok "写入 Nginx 配置：$NGX_CONF"
  fi
}

nginx_reload_smart() {
  # 不再死用 systemctl —— 这就是你遇到的坑
  nginx -t >/dev/null || die "Nginx 配置测试失败"

  # 1) systemd active -> reload
  if systemctl is-active nginx &>/dev/null; then
    systemctl reload nginx
    ok "Nginx 已通过 systemctl reload"
    return 0
  fi

  # 2) 有 master pid -> nginx -s reload
  local pid=""
  pid="$(ps -eo pid,comm,args | awk '$2=="nginx" && $3 ~ /master/ {print $1; exit}')"
  if [[ -n "$pid" ]]; then
    nginx -s reload
    ok "Nginx 已通过 nginx -s reload"
    return 0
  fi

  # 3) service wrapper（兼容）
  if has service; then
    if service nginx reload >/dev/null 2>&1; then
      ok "Nginx 已通过 service reload"
      return 0
    fi
  fi

  warn "检测到 nginx 但无法自动 reload（可能由面板/容器管理）。"
  warn "请在你的面板内执行“重载 Nginx/重启 Web 服务”。"
  return 1
}

print_proxy_snippets() {
  local target="http://127.0.0.1:3000"
  echo
  echo "=============================="
  echo "✅ 你的入口反代不由本脚本接管（符合零侵入原则）"
  echo "请在【你现有的入口反代】添加如下规则即可完成域名绑定："
  echo
  echo "【Nginx 站点片段】"
  cat <<EOF
server {
  listen 80;
  server_name ${DOMAIN};

  location / {
    proxy_pass ${target};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  echo
  echo "【Caddyfile 片段】"
  cat <<EOF
${DOMAIN} {
  reverse_proxy 127.0.0.1:3000
}
EOF
  echo
  echo "【宝塔 / 1Panel】"
  echo "站点 -> 反向代理 -> 目标URL：${target}  （Host 保持原域名）"
  echo "=============================="
  echo
}

bind_domain_lion() {
  # 目标：像科技lion一样“能落地”
  # 策略：
  # 1) 若 80 被 nginx/openresty 占用 -> 写独立站点并 smart reload（不要求 systemctl active）
  # 2) 若 80 空闲 -> 可选安装 nginx 并绑定（你可选择接管）
  # 3) 若 80 被非 nginx 占用 -> 不硬抢，直接输出可落地片段（你在现有入口反代粘贴即可）

  local owner line
  owner="$(port_owner 80)"
  line="$(listen_proc_line 80)"

  if [[ -z "$owner" ]]; then
    # 80 空闲：可接管
    warn "检测：80 端口空闲"
    read -rp "是否由脚本安装/使用 Nginx 接管 80 并绑定域名？(y/n): " yn
    if [[ "${yn:-n}" == "y" ]]; then
      if ! has nginx; then
        warn "安装 Nginx..."
        apt_install nginx >/dev/null
        # 不强行影响别的服务：这里只启动 nginx（因为你选择接管）
        systemctl enable --now nginx || true
      fi
      nginx_conf_write 80
      nginx_reload_smart || true
      ok "域名绑定完成（Nginx:80）"
      return 0
    else
      warn "你选择不接管 80：脚本将输出反代片段供你粘贴到现有入口。"
      print_proxy_snippets
      return 0
    fi
  fi

  if [[ "$owner" == "nginx" || "$owner" == "openresty" ]]; then
    ok "检测：80 端口由 Nginx/OpenResty 占用（可复用入口反代）"
    # 写独立站点 + smart reload
    nginx_conf_write 80
    # 可能会有 server_name 冲突：提示但不“失败”
    if nginx -t 2>&1 | grep -qi "conflicting server name"; then
      warn "检测到 server_name 冲突（同域名已在其它站点定义）。"
      warn "本脚本不会覆盖其它站点，请你删除/修改旧站点的 server_name 或在面板中调整。"
    fi
    nginx_reload_smart || true
    ok "已尝试应用 Nginx 配置（如面板管理，请在面板内重载 Nginx）"
    return 0
  fi

  # 非 nginx 占用：不抢，不动
  warn "检测：80 被其它服务占用（非 Nginx）"
  echo "占用详情：${line:-unknown}"
  print_proxy_snippets
  return 0
}

# ---------------- Deploy/Update/Uninstall ----------------
deploy() {
  echo
  read -rp "域名 (tv.example.com): " DOMAIN
  [[ -n "${DOMAIN:-}" ]] || die "域名不能为空"
  read -rp "管理员账号: " USER
  [[ -n "${USER:-}" ]] || die "账号不能为空"

  read -rp "密码输入是否明文显示？(y/n): " SHOWPASS
  SHOWPASS="${SHOWPASS:-n}"
  read_password_twice "$SHOWPASS"

  read -rp "启用 Cloudflare 自动解析 A 记录？(y/n): " CF
  CF="${CF:-n}"
  if [[ "$CF" == "y" ]]; then
    read -rp "CF 主域名(Zone，例如 example.com): " CF_ZONE
    [[ -n "${CF_ZONE:-}" ]] || die "CF_ZONE 不能为空"
    read_hidden_or_visible "CF API Token（隐藏输入）: " CF_TOKEN "n"
    [[ -n "${CF_TOKEN:-}" ]] || die "CF_TOKEN 不能为空"
  fi

  ensure_base

  if [[ "$CF" == "y" ]]; then
    cf_sync
  fi

  ensure_network
  write_env
  write_compose

  warn "拉起容器..."
  dc -f "$COMPOSE" up -d --remove-orphans
  ok "容器已启动"

  read -rp "是否绑定域名（科技lion式自动识别入口反代）？(y/n): " BIND
  BIND="${BIND:-y}"
  if [[ "$BIND" == "y" ]]; then
    bind_domain_lion
  else
    warn "跳过域名绑定。"
    print_proxy_snippets
  fi

  echo
  echo "=============================="
  echo "🎉 部署完成"
  echo "容器地址（本机回环）：http://127.0.0.1:3000"
  echo "域名：${DOMAIN}"
  echo "账号：${USER}"
  echo "密码：${PASS}"
  echo "目录：${BASE}"
  echo "提示：如域名不通，优先看“80/443 的入口反代是谁在管”，按脚本输出片段配置即可。"
  echo "=============================="
  echo
}

update_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，请先部署"
  warn "更新镜像..."
  dc -f "$COMPOSE" pull
  dc -f "$COMPOSE" up -d --remove-orphans
  ok "✅ 更新完成"
}

start_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，请先部署"
  dc -f "$COMPOSE" up -d --remove-orphans
  ok "✅ 已启动"
}

stop_app() {
  [[ -f "$COMPOSE" ]] || die "未找到 $COMPOSE，请先部署"
  dc -f "$COMPOSE" down
  ok "✅ 已停止"
}

rebind_domain() {
  [[ -r "$ENVF" ]] || warn "未找到 $ENVF，将要求你重新输入域名"
  if [[ -r "$ENVF" ]]; then
    # shellcheck disable=SC1090
    source "$ENVF" || true
    DOMAIN="${DOMAIN:-}"
  fi
  if [[ -z "${DOMAIN:-}" ]]; then
    read -rp "域名 (tv.example.com): " DOMAIN
  fi
  bind_domain_lion
}

uninstall() {
  read -rp "确认卸载 DecoTV？输入 yes 继续: " OKK
  [[ "${OKK:-}" == "yes" ]] || { warn "已取消"; return; }

  if [[ -f "$COMPOSE" ]]; then
    dc -f "$COMPOSE" down -v || true
  fi

  docker network rm "$NET" 2>/dev/null || true
  rm -rf "$BASE"

  # 不“乱删”你其它站点：只删本脚本写的 decotv 站点文件
  rm -f "$NGX_CONF" || true
  rm -f "$NGX_SITES_AVAIL" "$NGX_SITES_EN" || true

  # 不强制 reload（避免影响面板管理），但可尝试 smart reload
  if has nginx; then
    nginx_reload_smart || true
  fi

  ok "🗑️ 已卸载（尽量不影响其它服务）"
}

install_cli() {
  cp -f "$0" /usr/local/bin/decotv
  chmod +x /usr/local/bin/decotv
  ok "✅ 已安装快捷命令：decotv"
}

status() {
  echo "---- docker ps (decotv) ----"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'decotv-|kvrocks|NAMES' || true
  echo
  echo "---- port 80 owner ----"
  local l; l="$(listen_proc_line 80)"; echo "${l:-<free>}"
  echo
  echo "---- nginx test ----"
  if has nginx; then nginx -t || true; else echo "<nginx not installed>"; fi
}

# ---------------- Main ----------------
need_root

while true; do
  clear
  echo "==== ${APP} 管理面板 ===="
  echo "1) 一键部署（容器 + 科技lion式域名绑定）"
  echo "2) 更新镜像"
  echo "3) 启动服务"
  echo "4) 停止服务"
  echo "5) 重新绑定域名（自动识别入口反代）"
  echo "6) 状态诊断（端口/容器/nginx）"
  echo "7) 卸载"
  echo "8) 安装快捷命令（decotv）"
  echo "0) 退出"
  echo
  read -rp "选择: " C
  case "${C:-}" in
    1) deploy; pause ;;
    2) update_app; pause ;;
    3) start_app; pause ;;
    4) stop_app; pause ;;
    5) rebind_domain; pause ;;
    6) status; pause ;;
    7) uninstall; pause ;;
    8) install_cli; pause ;;
    0) exit 0 ;;
    *) warn "无效选择"; pause ;;
  esac
done
