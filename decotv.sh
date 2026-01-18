#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="DecoTV"

# ===== 固定路径（关键，保证快捷指令稳定）=====
RAW_URL="https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh"
PAYLOAD="/usr/local/share/decotv/decotv.sh"
LAUNCHER="/usr/local/bin/decotv"

DIR="/opt/decotv"
ENVF="$DIR/.env"
YML="$DIR/docker-compose.yml"

C1="decotv-core"
C2="decotv-kvrocks"

need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 root 运行（sudo -i）"; exit 1; }; }
pause(){ read -r -p "按回车继续..." _ || true; }
has(){ command -v "$1" >/dev/null 2>&1; }
installed(){ [[ -f "$ENVF" && -f "$YML" ]]; }
compose(){ (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }
kv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | cut -d= -f2- || true; }

ensure(){
  has curl || apt-get update -y && apt-get install -y curl ca-certificates
  has docker || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

install_shortcut(){
  echo "安装快捷指令 decotv ..."
  mkdir -p /usr/local/share/decotv
  curl -fsSL "$RAW_URL" -o "$PAYLOAD"
  chmod +x "$PAYLOAD"

  cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
exec bash $PAYLOAD "\$@"
EOF
  chmod +x "$LAUNCHER"
  hash -r 2>/dev/null || true
  echo "✔ 快捷指令已就绪：decotv"
}

pick_port(){
  for p in 3000 3001 3030 3080 3100 3200 8080; do
    ! ss -lnt | grep -q ":$p " && { echo "$p"; return; }
  done
  shuf -i 20000-60000 -n 1
}

write_cfg(){
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$1
PASSWORD=$2
APP_PORT=$3
EOF

  cat >"$YML" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: on-failure
    ports:
      - "${APP_PORT}:3000"
    environment:
      - USERNAME=${USERNAME}
      - PASSWORD=${PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://decotv-kvrocks:6666
    depends_on:
      - decotv-kvrocks

  decotv-kvrocks:
    image: apache/kvrocks
    container_name: decotv-kvrocks
    restart: unless-stopped
    volumes:
      - kvrocks-data:/var/lib/kvrocks

volumes:
  kvrocks-data:
EOF
}

deploy(){
  ensure
  read -r -p "用户名 [admin]：" u; u="${u:-admin}"
  while :; do
    read -r -p "密码（可见）：" p1
    read -r -p "确认密码：" p2
    [[ "$p1" == "$p2" && -n "$p1" ]] && break
    echo "密码不一致"
  done
  port="$(pick_port)"
  write_cfg "$u" "$p1" "$port"
  compose up -d
  install_shortcut
  echo
  echo "部署完成："
  echo "访问：http://$(curl -fsSL ifconfig.me):$port"
  echo "账号：$u"
  echo "密码：$p1"
}

uninstall(){
  read -r -p "确认卸载（将删除所有数据）？(y/n)：" a
  [[ "$a" != "y" ]] && return
  compose down -v --remove-orphans 2>/dev/null || true
  docker rm -f $C1 $C2 2>/dev/null || true
  rm -rf "$DIR"
  rm -f "$LAUNCHER" "$PAYLOAD"
  echo "已卸载并删除脚本"
  (sleep 1; rm -f "$0") &
  exit 0
}

menu(){
  clear
  echo "=============================="
  echo " DecoTV 运维面板"
  echo "=============================="
  echo "1) 部署"
  echo "2) 更新（重新拉取脚本+镜像）"
  echo "3) 卸载"
  echo "0) 退出"
}

update(){
  curl -fsSL "$RAW_URL" -o "$PAYLOAD"
  chmod +x "$PAYLOAD"
  compose pull
  compose up -d
  echo "更新完成"
}

main(){
  need_root
  while :; do
    menu
    read -r -p "请选择：" c
    case "$c" in
      1) deploy; pause ;;
      2) update; pause ;;
      3) uninstall ;;
      0) exit 0 ;;
    esac
  done
}

main "$@"
