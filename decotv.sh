#!/usr/bin/env bash
set -e

# ==============================
# DecoTV One-Click Manager
# install / update / uninstall
# ==============================

BASE_DIR="/opt/decotv"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
ENV_FILE="${BASE_DIR}/.env"
SERVICE_NAME="decotv"
IMAGE="ghcr.io/decohererk/decotv:latest"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}Docker 未安装，请先自行安装 Docker${RESET}"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Docker 服务未运行${RESET}"
    exit 1
  fi
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  else
    echo -e "${RED}未检测到 docker compose${RESET}"
    exit 1
  fi
}

install_decotv() {
  echo -e "${GREEN}开始安装 DecoTV...${RESET}"

  mkdir -p "$BASE_DIR"
  cd "$BASE_DIR"

  if [ ! -f "$ENV_FILE" ]; then
    read -rp "设置后台用户名: " ADMIN_USER
    read -rp "设置后台密码: " ADMIN_PASS
    read -rp "监听端口 (默认 3000): " PORT
    PORT=${PORT:-3000}

    cat > "$ENV_FILE" <<EOF
USERNAME=${ADMIN_USER}
PASSWORD=${ADMIN_PASS}
PORT=${PORT}
EOF
  fi

  if [ ! -f "$COMPOSE_FILE" ]; then
    cat > "$COMPOSE_FILE" <<EOF
version: "3.9"
services:
  decotv:
    image: ${IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "\${PORT}:3000"
EOF
  fi

  check_docker
  check_compose

  $COMPOSE pull
  $COMPOSE up -d

  PORT=$(grep PORT "$ENV_FILE" | cut -d= -f2)
  echo
  echo -e "${GREEN}DecoTV 安装完成${RESET}"
  echo "访问地址: http://服务器IP:${PORT}"
}

update_decotv() {
  echo -e "${YELLOW}更新 DecoTV 镜像...${RESET}"
  check_docker
  check_compose
  cd "$BASE_DIR"
  $COMPOSE pull
  $COMPOSE up -d
  echo -e "${GREEN}更新完成${RESET}"
}

uninstall_decotv() {
  echo -e "${RED}即将卸载 DecoTV${RESET}"
  read -rp "确认卸载？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消"
    exit 0
  fi

  if [ -d "$BASE_DIR" ]; then
    cd "$BASE_DIR"
    docker rm -f ${SERVICE_NAME} 2>/dev/null || true
    rm -rf "$BASE_DIR"
  fi

  echo -e "${GREEN}DecoTV 已彻底卸载${RESET}"
}

menu() {
  echo
  echo "=============================="
  echo " DecoTV 一键管理脚本"
  echo "=============================="
  echo "1) 安装 / 部署"
  echo "2) 更新镜像"
  echo "3) 卸载"
  echo "0) 退出"
  echo
  read -rp "请选择: " choice

  case "$choice" in
    1) install_decotv ;;
    2) update_decotv ;;
    3) uninstall_decotv ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

menu
