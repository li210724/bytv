#!/usr/bin/env bash
set -euo pipefail

APP="DecoTV v3 (No-Domain)"
BASE="/opt/decotv"
NET="decotv-net"
COMPOSE="$BASE/docker-compose.yml"
CLI="/usr/local/bin/decotv"

# ---------------- UI ----------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GRN}[OK]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
pause(){ read -rp "按 Enter 继续..."; }
need_root(){ [[ ${EUID:-999} -eq 0 ]] || die "请用 root 运行"; }
has(){ command -v "$1" &>/dev/null; }

# ---------------- OS/PKG ----------------
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

# ---------------- Compose wrapper ----------------
dc() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  elif has docker-compose; then
    docker-compose "$@"
  else
    die "未找到 docker compose / docker-compose"
  fi
}

# ---------------- Dependencies ----------------
ensure_base() {
  detect_os
  warn "检查并安装基础依赖..."
  apt_install ca-certificates curl jq iproute2 >/dev/null
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

# ---------------- Input (plain) ----------------
read_nonempty() {
  local prompt="$1" varname="$2" val=""
  while true; do
    read -rp "$prompt" val
    [[ -n "${val}" ]] && break
    warn "不能为空，请重试"
  done
  printf -v "$varname" '%s' "$val"
}

read_password_twice_plain() {
  local p1="" p2=""
  while true; do
    read -rp "管理员密码（明文输入）: " p1
    read -rp "再次输入密码（明文确认）: " p2
    [[ -n "$p1" ]] || { warn "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { warn "两次密码不一致，请重试"; continue; }
    PASS="$p1"
    break
  done
}

# ---------------- Compose ----------------
ensure_network() {
  if ! docker network inspect "$NET" &>/dev/null; then
    docker network create "$NET" >/dev/null
    ok "创建 Docker 网络：$NET"
  else
    ok "Docker 网络已存在：$NET"
  fi
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

# ---------------- Actions ----------------
deploy() {
  ensure_base
  ensure_network

  echo
  read_nonempty "管理员账号: " USER
  read_password_twice_plain

  write_compose

  warn "拉取并启动容器..."
  dc -f "$COMPOSE" up -d --remove-orphans
  ok "容器已启动"

  echo
  echo "=============================="
  echo "🎉 部署完成（无域名/无反代版本）"
  echo "本机访问： http://127.0.0.1:3000"
  echo "账号：${USER}"
  echo "密码：${PASS}"
  echo "目录：${BASE}"
  echo "提示：如需外网访问，请用你自己的反代/面板把域名反代到 127.0.0.1:3000"
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

status() {
  echo "---- containers ----"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'decotv-|NAMES' || true
  echo
  echo "---- health check ----"
  curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1 && echo "OK: 127.0.0.1:3000 可访问" || echo "WARN: 127.0.0.1:3000 暂不可访问（容器可能还在启动）"
}

uninstall() {
  read -rp "确认卸载 DecoTV？输入 yes 继续: " OKK
  [[ "${OKK:-}" == "yes" ]] || { warn "已取消"; return; }

  if [[ -f "$COMPOSE" ]]; then
    dc -f "$COMPOSE" down -v || true
  fi

  docker rm -f decotv-app decotv-kv 2>/dev/null || true
  docker network rm "$NET" 2>/dev/null || true

  rm -rf "$BASE"
  ok "🗑️ 已卸载（仅清理本项目目录/网络/容器/卷）"
}

install_cli() {
  cp -f "$0" "$CLI"
  chmod +x "$CLI"
  ok "✅ 已安装快捷命令：decotv"
}

# ---------------- Main ----------------
need_root
while true; do
  clear
  echo "==== ${APP} 管理面板 ===="
  echo "1) 一键部署（无域名/无反代）"
  echo "2) 更新镜像"
  echo "3) 启动服务"
  echo "4) 停止服务"
  echo "5) 状态检查"
  echo "6) 卸载"
  echo "7) 安装快捷命令（decotv）"
  echo "0) 退出"
  echo
  read -rp "选择: " C
  case "${C:-}" in
    1) deploy; pause ;;
    2) update_app; pause ;;
    3) start_app; pause ;;
    4) stop_app; pause ;;
    5) status; pause ;;
    6) uninstall; pause ;;
    7) install_cli; pause ;;
    0) exit 0 ;;
    *) warn "无效选择"; pause ;;
  esac
done
