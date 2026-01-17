#!/usr/bin/env bash
set -e

echo "====================================="
echo " DecoTV One-Key Deploy (Docker Only) "
echo "====================================="

# -------- 基础检查 --------
command -v docker >/dev/null 2>&1 || {
  echo "[ERROR] Docker 未安装，请先安装 Docker"
  exit 1
}

if command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  DC="docker compose"
fi

# -------- 目录 --------
BASE_DIR="/opt/decotv"
REPO_URL="https://github.com/Decohererk/DecoTV.git"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# -------- 拉取项目 --------
if [ ! -d ".git" ]; then
  echo "[+] 克隆 DecoTV 项目"
  git clone "$REPO_URL" .
else
  echo "[+] 已存在项目，跳过克隆"
fi

# -------- 配置 --------
if [ ! -f ".env" ]; then
  echo "[+] 生成默认配置"

  ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=+/')

  cat > .env <<EOF
PORT=3000
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASS}
EOF

  echo
  echo "====================================="
  echo " 后台登录信息（请保存）"
  echo "-------------------------------------"
  echo " 地址: http://服务器IP:3000"
  echo " 用户名: admin"
  echo " 密码: ${ADMIN_PASS}"
  echo "====================================="
  echo
else
  echo "[+] 已存在 .env，使用现有配置"
fi

# -------- 启动 --------
echo "[+] 启动 DecoTV"
$DC up -d

echo
echo "====================================="
echo " DecoTV 已启动"
echo "-------------------------------------"
echo " 访问地址: http://服务器IP:3000"
echo " Docker 状态:"
docker ps | grep decotv || true
echo "====================================="
