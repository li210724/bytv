# DecoTV 一键部署 & 运维脚本（交互式面板版）

![License](https://img.shields.io/github/license/li210724/bytv)
![Stars](https://img.shields.io/github/stars/li210724/bytv?style=flat)
![Issues](https://img.shields.io/github/issues/li210724/bytv)
![Last Commit](https://img.shields.io/github/last-commit/li210724/bytv)
![Shell](https://img.shields.io/badge/script-bash-green)

本仓库提供一个 **第三方、运维级、交互式** 的一键脚本 `decotv.sh`，  
用于在 VPS / 云服务器上 **稳定部署并长期维护 DecoTV（Docker 版）**。

脚本的设计目标非常明确：

> **不修改原项目、不侵入系统、不接管全局服务，  
> 只负责：部署、运行、更新、卸载。**

---

## 项目关系说明（重要）

本仓库 **不是 DecoTV 官方仓库**，而是一个 **独立的部署与运维工具**。

### DecoTV（原项目）
- 作者：Decohererk  
- 仓库：https://github.com/Decohererk/DecoTV  
- 职责：功能设计、前端与业务逻辑

### bytv（本仓库）
- 第三方部署与运维脚本
- 仅使用官方 Docker 镜像
- 不 Fork、不修改、不替代原项目
- 仅负责部署与运维自动化

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh)
```

运行后进入 **中文交互式管理面板**。

部署完成后将自动安装快捷命令：

```bash
decotv
```

---

## 当前脚本支持的功能

- Docker / Docker Compose 自动检测与安装
- 官方镜像部署（DecoTV + Kvrocks）
- Kvrocks 数据持久化
- 端口自动检测与避让
- 中文交互式菜单（适合手机 SSH）
- 运维功能：
  - 部署 / 重装
  - 更新
  - 状态查看
  - 日志查看（core / kvrocks）
  - 彻底卸载（含脚本本体）

---

# 反向代理完整教程（重点）

> **本脚本不会、也不应该自动配置反向代理或 HTTPS。**  
> 反向代理属于服务器级基础设施，应由用户自行管理。

下面给出一个 **从 0 到可用** 的完整反向代理教程，适合绝大多数使用场景。

---

## 一、什么时候需要反向代理？

- 使用域名访问而不是 IP:端口
- 需要 HTTPS
- 多 Web 服务共存
- 隐藏 DecoTV 实际端口

---

## 二、反向代理原理

```
用户浏览器
  ↓
https://tv.example.com
  ↓
反向代理（Nginx / Caddy / 面板）
  ↓
127.0.0.1:3000（DecoTV）
```

---

## 三、Nginx 反向代理（详细步骤）

### 1. 安装 Nginx

```bash
apt install -y nginx
```

### 2. 创建配置文件

```bash
nano /etc/nginx/conf.d/decotv.conf
```

```nginx
server {
    listen 80;
    server_name tv.example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### 3. 启用配置

```bash
nginx -t && nginx -s reload
```

---

## 四、HTTPS（两种方式）

### 方式一：Certbot

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d tv.example.com
```

### 方式二：Caddy

```caddy
tv.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

---

## 五、安全加固建议

- 反代成功后关闭 DecoTV 端口公网访问
- 仅通过 80/443 提供服务
- 使用防火墙或安全组限制端口

---

## 六、常见问题

- 不影响已有站点
- 可与宝塔 / 1Panel / 群晖共存
- 脚本不会内置反代（设计边界）

---

## 卸载

通过面板卸载将彻底清理：
- 容器
- 数据卷
- 快捷命令
- 脚本本体

---

## 免责声明

本项目为第三方运维工具，请合法使用。
