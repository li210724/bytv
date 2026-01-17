# DecoTV 一键部署 & 运维脚本（完整版）

![License](https://img.shields.io/github/license/li210724/bytv)
![Stars](https://img.shields.io/github/stars/li210724/bytv?style=flat)
![Issues](https://img.shields.io/github/issues/li210724/bytv)
![Last Commit](https://img.shields.io/github/last-commit/li210724/bytv)
![Shell](https://img.shields.io/badge/script-bash-green)

本仓库提供一个 **运维级、交互式** 的一键脚本 `decotv.sh`，用于在 VPS 上快速部署并长期维护 **DecoTV**。  
目标是：**不改原项目、不越权，只把部署和运维这件事做到省心、可靠、可回收。**

> **项目关系说明（重要）**  
>  
> 本仓库为 **DecoTV 的第三方部署与运维工具**，仅用于简化部署与长期维护流程：  
>  
> - **DecoTV（原项目）**  
>   - 作者：Decohererk  
>   - 仓库：https://github.com/Decohererk/DecoTV  
>   - 负责功能设计、代码实现与功能更新  
>  
> - **bytv（本项目）**  
>   - 第三方运维脚本，仅使用官方 Docker 镜像  
>   - 负责部署、HTTPS、备份、更新与运维自动化  
>  
> 本项目 **不修改、不 Fork、不替代** 原项目，  
> 功能相关问题请反馈至原项目仓库，  
> 部署或脚本问题再反馈至本仓库。

---

## 快速开始

### 一键运行（最快体验）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh)
```

运行后将进入交互式菜单，可完成部署、HTTPS 配置及后续运维。

---

## 安装为快捷启动面板（推荐）

在脚本菜单中选择：

```
13) 安装为系统命令(decotv)
```

脚本会自动将自身安装为系统命令：

```text
/usr/local/bin/decotv
```

之后即可在任意目录直接使用：

```bash
decotv
```

---

## 主要功能

- Docker + Docker Compose 自动安装
- 官方镜像部署（`ghcr.io/decohererk/decotv`）
- 默认 Kvrocks 持久化
- 可选 Nginx 反向代理
- Let's Encrypt 自动 HTTPS + 自动续期
- 交互式菜单 + 子命令
- 备份 / 恢复 / 更新 / 卸载

---

## 快捷命令一览

```bash
decotv                 # 打开快捷启动面板
decotv install         # 交互安装 / 部署
decotv status          # 查看状态
decotv start|stop      # 启动 / 停止
decotv restart         # 重启
decotv logs            # 查看日志
decotv update          # 更新镜像
decotv https           # 启用 / 修复 HTTPS
decotv backup          # 创建备份
decotv backups         # 备份列表
decotv restore         # 恢复备份
decotv uninstall       # 彻底卸载
```

---

## HTTPS 与证书说明

- 使用 Certbot + Nginx
- 自动申请 Let's Encrypt 证书
- 自动续期：
  - 优先 systemd `certbot.timer`
  - 兜底使用 `cron`

启用前请确认：
- 域名已解析到本机公网 IP
- 80 / 443 端口已放行（云安全组 + 防火墙）

---

## 备份与恢复

- 备份目录：`/opt/decotv/backups`
- 备份内容：
  - Kvrocks 数据
  - `docker-compose.yml`
  - Nginx 站点配置（如启用）

---

## 常见问题（FAQ）

### Q1：安装这个脚本会影响服务器上已有的域名吗？
**不会。**  
每个域名对应独立的 Nginx `server block`，不会覆盖或修改已有站点配置。  
仅在服务器仅使用 `default` 站点兜底的情况下，脚本会移除默认配置以避免域名误匹配（会提前提示）。

---

### Q2：HTTPS 证书会自动续期吗？
**会。**  
脚本会优先启用 `certbot.timer` 自动续期；  
若系统不支持，则写入 `cron` 任务作为兜底，无需人工干预。

---

### Q3：端口 3000 一定要对外开放吗？
不一定。  
启用 Nginx 后，用户访问走 80 / 443，  
3000 端口仅供本机反向代理使用，可在安全组中关闭对外访问。

---

### Q4：这个项目是官方的吗？
不是。  
这是 DecoTV 的 **第三方部署与运维工具**，  
功能相关问题请反馈至原项目仓库。

---

## 卸载

```bash
decotv uninstall
```

将删除：
- Docker 容器与数据
- Nginx 配置
- 系统命令 `decotv`
