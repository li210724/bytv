# DecoTV 一键部署 & 运维脚本（下载运行版）

![License](https://img.shields.io/github/license/li210724/bytv)
![Stars](https://img.shields.io/github/stars/li210724/bytv?style=flat)
![Issues](https://img.shields.io/github/issues/li210724/bytv)
![Last Commit](https://img.shields.io/github/last-commit/li210724/bytv)
![Shell](https://img.shields.io/badge/script-bash-green)

本仓库提供一个 **第三方、运维级、交互式** 的一键脚本 `decotv.sh`，  
用于在 VPS / 云服务器上 **稳定部署并长期维护 DecoTV（Docker 版）**。

> **运行方式说明（重要）**  
> 本项目采用 **“下载脚本 → 本地执行”** 的方式运行，  
> **不使用** `bash <(curl ...)` 的进程替换形式，  
> 以避免 Shell 缓存、路径不稳定等历史问题。

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

## 快速开始（推荐方式）

### 1️⃣ 下载脚本

```bash
curl -fsSL https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh -o decotv.sh
```

### 2️⃣ 赋予执行权限

```bash
chmod +x decotv.sh
```

### 3️⃣ 运行脚本

```bash
sudo ./decotv.sh
```

运行后进入 **中文交互式管理面板**，  
可完成部署、查看状态、日志与卸载。

> 以后需要管理时，**再次执行当前目录下的 `decotv.sh` 即可**。

---

## 当前脚本支持的功能

以下内容 **与当前脚本实际能力完全一致**：

- Docker / Docker Compose 自动检测与安装
- 官方镜像部署：
  - `ghcr.io/decohererk/decotv`
  - `apache/kvrocks`
- Kvrocks 数据持久化
- **端口手动选择**（默认 3000）
- 中文交互式菜单（适合手机 SSH）
- 运维功能：
  - 部署 / 重装
  - 状态查看
  - 日志查看（core / kvrocks）
  - 彻底卸载（容器 / 数据 / 工作目录）

---

## 访问方式说明

部署完成后，脚本会 **当场输出并明确提示**：

- 访问地址（IP + 实际端口）
- 用户名
- 密码
- 使用端口

示例：

```
http://服务器IP:3000
```

> 面板首页不会重复显示账号信息，  
> 请在部署完成时妥善保存凭据。

---

# 反向代理完整教程（重点）

> **本脚本不会、也不应该自动配置反向代理或 HTTPS。**  
> 反向代理属于服务器级基础设施，应由用户自行管理。

下面给出一个 **从 0 到可用** 的完整反向代理教程，适合绝大多数使用场景。

---

## 一、什么时候需要反向代理？

你在以下情况 **应该使用反向代理**：

- 希望使用 **域名** 而不是 `IP:端口` 访问
- 希望使用 **HTTPS**
- 服务器上已有多个 Web 服务，需要统一入口
- 想隐藏 DecoTV 实际监听端口

如果你只是自用测试：  
**直接使用 `http://IP:端口` 即可，无需反代。**

---

## 二、反向代理的基本原理

```
用户浏览器
     │
     ▼
https://tv.example.com   （80 / 443）
     │
     ▼
Nginx / Caddy / 面板反代
     │
     ▼
127.0.0.1:3000           （DecoTV 实际端口）
```

DecoTV **只监听本机端口**，  
所有公网访问由反向代理接管。

---

## 三、使用 Nginx 进行反向代理（详细步骤）

### 1. 前置条件

- 已安装 Nginx
- 域名已解析到服务器公网 IP
- 防火墙 / 安全组已放行 80（和 443）端口

---

### 2. 新建站点配置文件

假设：
- 域名：`tv.example.com`
- DecoTV 端口：`3000`

创建配置文件：

```bash
nano /etc/nginx/conf.d/decotv.conf
```

写入内容：

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

---

### 3. 检查并重载 Nginx

```bash
nginx -t
nginx -s reload
```

访问：

```
http://tv.example.com
```

如能正常访问，说明反向代理已生效。

---

## 四、HTTPS 配置建议

### 方案一：Nginx + Certbot

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d tv.example.com
```

### 方案二：Caddy（更简单）

```caddy
tv.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

---

## 五、安全建议（强烈推荐）

当反向代理工作正常后：

- **关闭 DecoTV 端口的公网访问**
- 仅允许 `127.0.0.1` 或内网访问
- 所有外部流量只通过 80 / 443

---

## 常见问题（FAQ）

### Q1：会影响我服务器上已有站点吗？
不会。  
每个域名对应独立的反代配置，互不干扰。

### Q2：可以用宝塔 / 1Panel / 群晖反代吗？
可以。  
本质都是将域名转发到：

```
127.0.0.1:DecoTV端口
```

### Q3：为什么不内置反代或 HTTPS？
这是明确的设计边界，  
避免脚本越权操作系统级服务。

---

## 卸载说明

在脚本菜单中选择 **卸载**：

- 删除 DecoTV 相关容器
- 删除 Kvrocks 数据卷
- 删除项目工作目录（`/opt/decotv`）

卸载后系统恢复为未安装状态。

---

## 免责声明

本项目为 **第三方部署与运维工具**，  
不对 DecoTV 原项目功能负责。

请遵守当地法律法规，合理合法使用。
