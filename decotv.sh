#!/usr/bin/env bash
set -e

echo "====================================="
echo " DecoTV One-Key Deploy (Docker Only) "
echo "====================================="
echo

# ---------- 基础检查 ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker 未安装，请先安装 Docker"
  exit 1
fi

if command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  DC="docker compose"
fi

# ---------- 目录 ----------
BASE_DIR="/opt/decotv"
REPO_URL="https://github.com/Decohererk/DecoTV.git"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ---------- 获取服务器 IP ----------
SERVER_IP=$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')

# ---------- 拉取项目 ----------
if [ ! -d ".git" ]; then
  echo "[+] 克隆 DecoTV 项目"
  git clone "$REPO_URL" .
else
  echo "[+] 已存在 DecoTV 项目，跳过克隆"
fi

echo

# ---------- 用户输入 ----------
read -rp "后台用户名（默认 admin）： " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -rsp "后台密码（留空自动生成强密码）： " ADMIN_PASS
echo
if [ -z "$ADMIN_PASS" ]; then
  ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=+/')
  PASS_AUTO_GEN=1
else
  PASS_AUTO_GEN=0
fi

PORT=3000

# ---------- 写入配置 ----------
echo "[+] 写入配置文件 .env"
cat > .env <<EOF
PORT=${PORT}
ADMIN_USERNAME=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASS}
EOF

echo

# ---------- 启动 ----------
echo "[+] 启动 DecoTV 容器"
$DC up -d

echo
echo "====================================="
echo " DecoTV 部署完成"
echo "-------------------------------------"
echo " 访问地址 : http://${SERVER_IP}:${PORT}"
echo " 用户名   : ${ADMIN_USER}"
if [ "$PASS_AUTO_GEN" -eq 1 ]; then
  echo " 密码     : ${ADMIN_PASS}  (自动生成)"
else
  echo " 密码     : （你刚刚设置的那个）"
fi
echo "-------------------------------------"
echo " 容器状态 :"
docker ps | grep decotv || true
echo "====================================="
