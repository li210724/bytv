# DecoTV 一键部署 & 运维脚本（完整版）

![License](https://img.shields.io/github/license/li210724/bytv)
![Stars](https://img.shields.io/github/stars/li210724/bytv?style=flat)
![Issues](https://img.shields.io/github/issues/li210724/bytv)
![Last Commit](https://img.shields.io/github/last-commit/li210724/bytv)
![Shell](https://img.shields.io/badge/script-bash-green)

本仓库提供一个 **运维级、交互式** 的一键脚本 `decotv.sh`，用于在 VPS 上快速部署并长期维护 **DecoTV**：

- Docker Compose 部署（自带 **Kvrocks** 持久化）
- 可选 **Nginx** 反代
- **Let's Encrypt 自动证书 + 自动续期**
- **备份 / 恢复**
- 更新、日志、状态、彻底卸载
- 支持安装为系统命令：`decotv`（快捷启动面板 + 子命令）

---

## 原项目介绍（DecoTV）

**DecoTV** 是一个开源项目（原仓库：`Decohererk/DecoTV`），本脚本使用其官方镜像进行部署：

- 官方仓库：https://github.com/Decohererk/DecoTV
- Docker 镜像：`ghcr.io/decohererk/decotv:latest`
- Web 端口：容器内 `3000`

> 本仓库 **不修改 DecoTV 源码**，仅提供更稳定、更自动化的部署与运维能力。

---

## 本项目介绍（li210724/bytv）

这是一个 **“面板化思维”** 的运维脚本：

- 一次部署，长期使用
- 菜单 + 命令双模式
- 自动 HTTPS、自动续期
- 出问题可恢复、可卸载、不留垃圾

适合：
- 自建 / 私用
- 长期跑在 VPS 上
- 不想天天 SSH 手搓命令的人

---

## 一键运行（最快上手）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh)
```

> 这是“临时运行模式”，适合首次体验。

---

## 安装为快捷启动面板（强烈推荐）

在菜单中选择：

```
13) 安装为系统命令(decotv)
```

即使你是通过 `bash <(curl ...)` 方式运行，  
脚本也会 **自动从仓库 RAW 下载自身并安装** 到：

```
/usr/local/bin/decotv
```

之后即可随时使用：

```bash
decotv
```

---

## 快捷指令一览

```bash
decotv                 # 打开快捷启动面板
decotv install         # 交互安装/部署
decotv status          # 查看状态
decotv start|stop      # 启动/停止
decotv restart         # 重启
decotv logs            # 跟随日志
decotv update          # 更新镜像
decotv https           # 启用/修复 HTTPS
decotv backup          # 创建备份
decotv backups         # 备份列表
decotv restore         # 恢复备份
decotv uninstall       # 彻底卸载
```

---

## HTTPS 自动证书说明

- 使用 **Certbot + Nginx**
- 自动申请 Let's Encrypt 证书
- 自动续期：
  - 优先 `systemd certbot.timer`
  - 兜底使用 `cron`

### 启用条件

- 域名 A / AAAA 解析到本机公网 IP（脚本会校验）
- 放行端口 **80 / 443**（云安全组 + 防火墙）

---

## 备份与恢复

- 备份目录：`/opt/decotv/backups`
- 备份内容：
  - Kvrocks 数据
  - `docker-compose.yml`
  - Nginx 站点配置（如启用）

```bash
decotv backup     # 创建备份
decotv backups    # 查看备份
decotv restore    # 恢复备份
```

---

## 常见问题（FAQ）

### Q1：HTTPS 申请失败？

请检查：
1. 域名是否正确解析到本机 IP
2. 80 / 443 是否放行（尤其是云厂商安全组）
3. `nginx -t` 是否通过

---

### Q2：证书会过期吗？

不会。  
脚本已自动配置 **证书续期机制**，无需人工干预。

---

### Q3：端口 3000 能关吗？

可以。  
启用 Nginx 后，用户访问走 80/443，3000 仅供本机反代使用。

---

### Q4：支持哪些系统？

- Ubuntu / Debian（推荐）
- AlmaLinux / Rocky / CentOS Stream（可用）

---

## 更新日志（Changelog）

### v1.0.0
- 初始版本
- 一键部署 DecoTV
- Nginx + HTTPS + 自动续期
- 备份 / 恢复
- 快捷启动面板

---

## 目录说明

- 程序目录：`/opt/decotv`
- 数据目录：`/opt/decotv/data`
- 备份目录：`/opt/decotv/backups`

---

## 卸载

```bash
decotv uninstall
```

将删除：
- 所有容器与数据
- Nginx 配置
- 系统命令 `decotv`
