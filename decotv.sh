#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# DecoTV One-key Deploy (Docker Compose)
#
# Safety rules:
# - Only touches: /opt/decotv (and subpaths)
# - Only manages containers: decotv-core, decotv-kvrocks
# - Does NOT assume 80/443 are available
# - Does NOT modify nginx.conf / default site / other sites
# - If nginx config is generated, it does NOT reload/restart nginx
#
# Usage:
#   bash decotv-onekey.sh              # install/update & start
#   bash decotv-onekey.sh status       # show status
#   bash decotv-onekey.sh logs         # show last 200 logs
#   bash decotv-onekey.sh restart      # restart
#   bash decotv-onekey.sh stop         # stop
#   bash decotv-onekey.sh uninstall    # uninstall (only this project)
# ==========================================================

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP_NAME="decotv"
APP_DIR="/opt/${APP_NAME}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${APP_DIR}/.env"
KV_DATA_DIR="${APP_DIR}/kvrocks-data"
NGINX_DIR_LOCAL="${APP_DIR}/nginx"
NGINX_PREFIX="decotv"

# ---------- Pretty output ----------
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"
  C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"; C_CYAN="\033[36m"
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

ok()   { printf "%b[OK]%b %s\n"   "$C_GREEN" "$C_RESET" "$*"; }
info() { printf "%b[INFO]%b %s\n" "$C_CYAN"  "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%b[ERR]%b %s\n"  "$C_RED"   "$C_RESET" "$*"; }
die()  { err "$*"; exit 1; }

hr() { printf "%b%s%b\n" "$C_BLUE" "==================================================" "$C_RESET"; }

banner() {
  hr
  printf "%bDecoTV · One-key Deploy%b\n" "$C_BOLD" "$C_RESET"
  printf "Dir: %s\n" "$APP_DIR"
  hr
}

# ---------- helpers ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root: sudo -i  (then rerun)"
  fi
}

os_id() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

pm_detect() {
  if have_cmd apt-get; then echo apt
  elif have_cmd dnf; then echo dnf
  elif have_cmd yum; then echo yum
  elif have_cmd pacman; then echo pacman
  else echo unknown
  fi
}

pkg_install() {
  local pm; pm="$(pm_detect)"
  local pkgs=("$@")

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
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    *)
      die "Unknown package manager. Please install manually: ${pkgs[*]}"
      ;;
  esac
}

rand_port() {
  if have_cmd shuf; then
    shuf -i 20000-60000 -n 1
  elif have_cmd python3; then
    python3 - <<'PY'
import random
print(random.randint(20000, 60000))
PY
  else
    echo 34567
  fi
}

is_port_valid() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

detect_ip() {
  local ip=""
  if have_cmd curl; then
    ip="$(curl -fsSL https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]] && have_cmd ip; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

compose_cmd() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif have_cmd docker-compose; then
    echo "docker-compose"
  else
    return 1
  fi
}

ensure_basics() {
  info "Checking basic dependencies..."
  local need=(curl)
  for c in "${need[@]}"; do
    if ! have_cmd "$c"; then
      warn "Missing command: $c (will install)"
      pkg_install curl ca-certificates
      break
    fi
  done

  # Some distros don't have ip by default
  if ! have_cmd ip; then
    warn "Missing command: ip (will install iproute2/iproute)"
    # best-effort
    pkg_install iproute2 >/dev/null 2>&1 || pkg_install iproute >/dev/null 2>&1 || true
  fi

  ok "Basic dependencies ready."
}

install_docker_if_needed() {
  if have_cmd docker; then
    ok "Docker found: $(docker --version 2>/dev/null || true)"
  else
    warn "Docker not found. Installing Docker + Compose plugin..."

    local pm; pm="$(pm_detect)"
    if [[ "$pm" == "apt" ]]; then
      pkg_install ca-certificates curl gnupg lsb-release

      install -m 0755 -d /etc/apt/keyrings
      local os; os="$(os_id)"
      curl -fsSL "https://download.docker.com/linux/${os}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      # shellcheck disable=SC1091
      . /etc/os-release
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      # best-effort for non-apt (may be older)
      pkg_install docker >/dev/null 2>&1 || true
      pkg_install docker-compose >/dev/null 2>&1 || true
    fi

    have_cmd docker || die "Docker install failed. Please install Docker manually and rerun."
    ok "Docker installed: $(docker --version 2>/dev/null || true)"

    if have_cmd systemctl; then
      systemctl enable --now docker >/dev/null 2>&1 || true
    fi
  fi

  if ! compose_cmd >/dev/null 2>&1; then
    warn "Docker Compose not found. Trying to install compose plugin..."
    local pm; pm="$(pm_detect)"
    if [[ "$pm" == "apt" ]]; then
      apt-get update -y
      apt-get install -y docker-compose-plugin
    else
      pkg_install docker-compose >/dev/null 2>&1 || true
    fi
  fi

  compose_cmd >/dev/null 2>&1 || die "Docker Compose is still missing."
  ok "Compose ready: $($(compose_cmd) version 2>/dev/null | head -n 1 || true)"
}

# ---------- project ops ----------
write_project_files() {
  mkdir -p "$APP_DIR" "$KV_DATA_DIR" "$NGINX_DIR_LOCAL"

  cat > "$ENV_FILE" <<EOF
# Generated by decotv-onekey.sh
USERNAME=${ADMIN_USER}
PASSWORD=${ADMIN_PASS}

# Storage (recommended)
NEXT_PUBLIC_STORAGE_TYPE=kvrocks
KVROCKS_URL=redis://decotv-kvrocks:6666
EOF

  cat > "$COMPOSE_FILE" <<EOF
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:${IMAGE_TAG}
    container_name: decotv-core
    restart: on-failure
    ports:
      - "${HOST_PORT}:3000"
    env_file:
      - .env
    depends_on:
      - decotv-kvrocks
    networks:
      - decotv-network

  decotv-kvrocks:
    image: apache/kvrocks
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes:
      - ./kvrocks-data:/var/lib/kvrocks
    networks:
      - decotv-network

networks:
  decotv-network:
    driver: bridge
EOF

  ok "Wrote: ${ENV_FILE}"
  ok "Wrote: ${COMPOSE_FILE}"
}

dc_up() {
  local c; c="$(compose_cmd)"
  (cd "$APP_DIR" && $c pull && $c up -d)
}

dc_down() {
  local c; c="$(compose_cmd)"
  (cd "$APP_DIR" && $c down)
}

dc_status() {
  local c; c="$(compose_cmd)"
  (cd "$APP_DIR" && $c ps)
}

dc_logs() {
  local c; c="$(compose_cmd)"
  (cd "$APP_DIR" && $c logs -n 200 --no-color)
}

nginx_generate_conf() {
  local domain="$1"
  local host_port="$2"

  local local_path="${NGINX_DIR_LOCAL}/${NGINX_PREFIX}-${domain}.conf"
  cat > "$local_path" <<EOF
# DecoTV reverse proxy (generated)
# Safe: This file is generated under ${APP_DIR}. You can copy it manually.

server {
  listen 80;
  server_name ${domain};

  location / {
    proxy_pass http://127.0.0.1:${host_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  ok "Generated nginx snippet: ${local_path}"

  if have_cmd nginx && [[ -d /etc/nginx/conf.d ]]; then
    local sys_path="/etc/nginx/conf.d/${NGINX_PREFIX}-${domain}.conf"
    cat > "$sys_path" <<EOF
# DecoTV reverse proxy (generated by decotv-onekey.sh)
# Safe: does NOT touch nginx.conf / default site; just adds this file.

server {
  listen 80;
  server_name ${domain};

  location / {
    proxy_pass http://127.0.0.1:${host_port};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
    ok "Also wrote: ${sys_path}"
    warn "Nginx is NOT reloaded by this script. Run manually: nginx -t && systemctl reload nginx"
  else
    warn "nginx not detected (or /etc/nginx/conf.d missing). Snippet is generated; use your own reverse proxy."
  fi
}

uninstall_project() {
  banner
  warn "This will remove ONLY DecoTV project directory and its containers."
  read -r -p "Type 'YES' to confirm uninstall: " x
  [[ "$x" == "YES" ]] || die "Cancelled."

  if [[ -d "$APP_DIR" ]]; then
    warn "Stopping containers (if running)..."
    dc_down >/dev/null 2>&1 || true
    rm -rf "$APP_DIR"
    ok "Removed: ${APP_DIR}"
  else
    warn "Not installed: ${APP_DIR}"
  fi

  if [[ -d /etc/nginx/conf.d ]]; then
    rm -f /etc/nginx/conf.d/${NGINX_PREFIX}-*.conf >/dev/null 2>&1 || true
  fi
  ok "Uninstall done. (Docker not removed)"
}

# ---------- interactive flow ----------
prompt_install() {
  banner

  read -r -p "Admin username [admin]: " ADMIN_USER || true
  ADMIN_USER="${ADMIN_USER:-admin}"

  while true; do
    local p1 p2
    read -r -s -p "Admin password (will be shown later): " p1 || true
    echo
    [[ -n "$p1" ]] || { warn "Password cannot be empty."; continue; }
    read -r -s -p "Confirm password: " p2 || true
    echo
    if [[ "$p1" != "$p2" ]]; then
      warn "Passwords do not match. Try again."
      continue
    fi
    ADMIN_PASS="$p1"
    break
  done

  read -r -p "Image tag [latest]: " IMAGE_TAG || true
  IMAGE_TAG="${IMAGE_TAG:-latest}"

  while true; do
    read -r -p "Host port (1-65535, empty=random 20000-60000): " HOST_PORT || true
    HOST_PORT="${HOST_PORT:-$(rand_port)}"
    if is_port_valid "$HOST_PORT"; then
      break
    fi
    warn "Invalid port: ${HOST_PORT}"
  done

  read -r -p "Domain for reverse proxy (optional, empty=skip): " DOMAIN || true
  DOMAIN="${DOMAIN:-}"

  hr
  printf "%bReview settings%b\n" "$C_BOLD" "$C_RESET"
  printf "- Username : %s\n" "$ADMIN_USER"
  printf "- Password : %s\n" "$ADMIN_PASS"
  printf "- ImageTag : %s\n" "$IMAGE_TAG"
  printf "- Port     : %s\n" "$HOST_PORT"
  printf "- Domain   : %s\n" "${DOMAIN:-<none>}"
  hr

  read -r -p "Proceed with deploy? [y/N]: " yn
  case "${yn:-}" in
    y|Y|yes|YES) ;;
    *) die "Cancelled." ;;
  esac
}

print_access() {
  local ip; ip="$(detect_ip)"
  hr
  printf "%bDeployed successfully%b\n" "$C_BOLD" "$C_RESET"
  printf "Access URL : http://%s:%s\n" "$ip" "$HOST_PORT"
  printf "Admin URL  : http://%s:%s/admin\n" "$ip" "$HOST_PORT"
  printf "Username   : %s\n" "$ADMIN_USER"
  printf "Password   : %s\n" "$ADMIN_PASS"
  if [[ -n "${DOMAIN:-}" ]]; then
    printf "Domain     : %s\n" "$DOMAIN"
  fi
  hr
  warn "Reminder: DecoTV needs you to configure sources in the admin panel after first login."
}

install_flow() {
  need_root
  ensure_basics
  install_docker_if_needed
  prompt_install

  info "Writing project files..."
  write_project_files

  info "Starting containers..."
  dc_up

  ok "Containers started."
  dc_status || true

  if [[ -n "${DOMAIN:-}" ]]; then
    info "Generating nginx reverse-proxy config (optional)..."
    nginx_generate_conf "$DOMAIN" "$HOST_PORT" || true
  fi

  print_access
}

show_help() {
  cat <<EOF
DecoTV One-key Deploy

Usage:
  bash $0                install/update & start
  bash $0 install         same as above
  bash $0 status          show status
  bash $0 logs            show last 200 logs
  bash $0 restart         restart service
  bash $0 stop            stop service
  bash $0 uninstall       uninstall ONLY this project
EOF
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install|"")
      install_flow
      ;;
    status)
      need_root
      [[ -d "$APP_DIR" ]] || die "Not installed: ${APP_DIR}"
      dc_status
      ;;
    logs)
      need_root
      [[ -d "$APP_DIR" ]] || die "Not installed: ${APP_DIR}"
      dc_logs
      ;;
    restart)
      need_root
      [[ -d "$APP_DIR" ]] || die "Not installed: ${APP_DIR}"
      dc_down || true
      dc_up
      dc_status || true
      ;;
    stop|down)
      need_root
      [[ -d "$APP_DIR" ]] || die "Not installed: ${APP_DIR}"
      dc_down
      ok "Stopped."
      ;;
    uninstall|remove)
      need_root
      uninstall_project
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      show_help
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
