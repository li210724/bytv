#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

APP="DecoTV"
DIR="/opt/decotv"; ENVF="$DIR/.env"; YML="$DIR/docker-compose.yml"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "请用 root 运行（sudo -i）"; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
pm(){ has apt-get&&echo apt||has dnf&&echo dnf||has yum&&echo yum||has pacman&&echo pacman||echo none; }
pause(){ read -r -p "按回车继续..." _ || true; }
installed(){ [[ -f "$ENVF" && -f "$YML" ]]; }
compose(){ (cd "$DIR" && docker compose --env-file "$ENVF" "$@"); }

inst_pkgs(){
  local m; m="$(pm)"
  case "$m" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
         DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null ;;
    dnf) dnf install -y "$@" >/dev/null ;;
    yum) yum install -y "$@" >/dev/null ;;
    pacman) pacman -Sy --noconfirm "$@" >/dev/null ;;
    *) echo "不支持的包管理器，请手动安装：$*"; exit 1 ;;
  esac
}

ensure(){
  has curl || inst_pkgs curl ca-certificates
  if ! has docker; then curl -fsSL https://get.docker.com | sh; fi
  has systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || inst_pkgs docker-compose-plugin || true
  docker compose version >/dev/null 2>&1 || { echo "Docker Compose 不可用，请手动安装 compose 插件"; exit 1; }
}

ip(){
  curl -fsSL https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'
}

inuse(){ has ss && ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
pick_port(){
  local p="${1:-3000}"
  if [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1&&p<=65535)) && ! inuse "$p"; then echo "$p"; return; fi
  for x in 3000 3001 3030 3080 3100 3200 8080 18080; do ! inuse "$x" && { echo "$x"; return; }; done
  while :; do x="$(shuf -i 20000-60000 -n 1 2>/dev/null || echo 3000)"; ! inuse "$x" && { echo "$x"; return; }; done
}

kv(){ grep -E "^$1=" "$ENVF" 2>/dev/null | head -n1 | cut -d= -f2- || true; }

访问地址(){
  if ! installed; then echo "未安装"; return; fi
  local p u host
  p="$(kv APP_PORT)"; u="$(kv USERNAME)"
  host="$(ip || true)"; [[ -z "${host:-}" ]] && host="<服务器IP>"
  echo "http://${host}:${p:-?}（账号：${u:-?}）"
}

运行状态(){
  if ! installed; then echo "未安装"; return; fi
  local n
  n="$(compose ps --status running 2>/dev/null | awk 'NR>1{print $1}' | wc -l | tr -d ' ')"
  [[ "$n" == "2" ]] && echo "运行中" || echo "未完全运行"
}

write_cfg(){
  local port="$1" user="$2" pass="$3"
  mkdir -p "$DIR"
  cat >"$ENVF" <<EOF
USERNAME=$user
PASSWORD=$pass
APP_PORT=$port
EOF
  cat >"$YML" <<'EOF'
services:
  decotv-core:
    image: ghcr.io/decohererk/decotv:latest
    container_name: decotv-core
    restart: on-failure
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
networks: { decotv-network: { driver: bridge } }
volumes: { kvrocks-data: {} }
EOF
}

部署(){
  ensure
  if installed; then
    read -r -p "检测到已安装，是否覆盖并重建？(y/n) [n]：" a
    [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  fi

  read -r -p "设置用户名 [admin]：" user; user="${user:-admin}"
  while :; do
    read -r -p "设置密码（可见）：" p1
    read -r -p "再次确认（可见）：" p2
    [[ -n "${p1:-}" ]] || { echo "密码不能为空"; continue; }
    [[ "$p1" == "$p2" ]] || { echo "两次密码不一致"; continue; }
    break
  done
  read -r -p "外部访问端口 [3000]：" pp; pp="${pp:-3000}"
  port="$(pick_port "$pp")"
  [[ "$port" != "$pp" ]] && echo "端口 $pp 已占用，自动选用：$port"

  write_cfg "$port" "$user" "$p1"
  compose up -d
  echo "部署完成：$(访问地址)"
}

更新(){
  ensure; installed || { echo "未安装，请先部署"; return; }
  compose pull
  compose up -d
  echo "更新完成：$(访问地址)"
}

状态(){
  ensure; installed || { echo "未安装"; return; }
  compose ps || true
  echo "运行状态：$(运行状态)"
  echo "访问地址：$(访问地址)"
  echo "密码：$(kv PASSWORD)"
}

日志(){
  ensure; installed || { echo "未安装"; return; }
  echo "提示：按 Ctrl+C 退出日志"
  compose logs -f --tail=200
}

卸载(){
  ensure
  read -r -p "确认卸载（容器+卷+网络+目录）？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }

  if installed; then
    (cd "$DIR" && docker compose --env-file "$ENVF" down -v --remove-orphans) || true
  else
    docker rm -f decotv-core >/dev/null 2>&1 || true
    docker rm -f decotv-kvrocks >/dev/null 2>&1 || true
  fi
  docker network rm decotv-network >/dev/null 2>&1 || true
  docker volume rm kvrocks-data >/dev/null 2>&1 || true

  read -r -p "是否删除镜像（释放空间）？(y/n) [y]：" b
  if [[ "${b:-y}" == "y" ]]; then
    docker rmi -f ghcr.io/decohererk/decotv:latest >/dev/null 2>&1 || true
    docker rmi -f apache/kvrocks:latest >/dev/null 2>&1 || true
  fi

  rm -rf "$DIR" || true
  echo "卸载完成"
}

清理(){
  ensure
  echo "仅清理未使用资源：停止容器/悬空镜像/未使用网络/未使用卷"
  read -r -p "确认执行 Docker 清理？(y/n) [n]：" a
  [[ "${a:-n}" == "y" ]] || { echo "已取消"; return; }
  docker system prune -f || true
  docker volume prune -f || true
  echo "清理完成"
}

菜单(){
  clear 2>/dev/null || true
  echo "=============================="
  echo " ${APP} · 交互式管理面板"
  echo "=============================="
  echo "当前状态：$(运行状态) ｜ 访问：$(访问地址)"
  echo
  echo "1) 部署 / 重装"
  echo "2) 更新（拉取最新镜像）"
  echo "3) 状态（查看信息/密码）"
  echo "4) 日志（实时跟踪）"
  echo "5) 卸载（尽量彻底）"
  echo "6) 清理（Docker 垃圾清理）"
  echo "0) 退出"
  echo
}

main(){
  need_root
  while :; do
    菜单
    read -r -p "请选择 [0-6]：" c
    case "${c:-}" in
      1) 部署; pause ;;
      2) 更新; pause ;;
      3) 状态; pause ;;
      4) 日志 ;;
      5) 卸载; pause ;;
      6) 清理; pause ;;
      0) exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

main "$@"
