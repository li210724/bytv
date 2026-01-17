# DecoTV 一键部署 & 运维脚本（完整版）

本仓库提供一个 **运维级、交互式** 的一键脚本 `decotv.sh`，用于在 VPS 上快速部署并长期维护 **DecoTV**：
- Docker Compose 部署（自带 Kvrocks 持久化）
- 可选 Nginx 反代
- **Let's Encrypt 自动证书 + 自动续期**
- **备份 / 恢复**
- 更新、日志、状态、彻底卸载
- 支持安装为系统命令：`decotv`（快捷启动面板）

---

## 1. 原项目介绍（DecoTV）

**DecoTV** 是一个开源项目（原仓库：`Decohererk/DecoTV`），本脚本使用其官方镜像进行部署：
- 镜像：`ghcr.io/decohererk/decotv:latest`
- 运行端口：容器内 `3000`

> 本仓库不修改 DecoTV 源码，只提供更“运维友好”的部署与管理能力。

---

## 2. 本项目介绍（li210724/bytv）

你将得到一个“像面板一样好用”的运维脚本：

- ✅ 一次部署，后续用命令/菜单维护
- ✅ 域名解析校验（DNS -> 本机公网 IP），避免证书申请失败
- ✅ Nginx 反代 + HTTPS 证书全自动（certbot --nginx）
- ✅ 证书自动续期（优先 systemd timer；不支持则写入 cron）
- ✅ 备份/恢复（数据 + compose + nginx 配置）
- ✅ 一键彻底卸载（容器 + 数据 + 配置 + 命令）

---

## 3. 一键运行（推荐）

> 直接在服务器执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/li210724/bytv/main/decotv.sh)
```

---

## 4. 安装为“快捷启动面板”命令（强烈推荐）

脚本菜单里选择 **“安装为系统命令(decotv)”**，或直接执行：

```bash
sudo bash decotv.sh cmd
```

之后你就可以像打开面板一样用：

```bash
decotv
```

---

## 5. 快捷指令（面板 + 命令两用）

> 安装为命令后，下面这些指令都可直接用：

```bash
decotv                 # 打开快捷启动面板(交互菜单)
decotv install         # 交互安装/部署
decotv status          # 查看状态
decotv start|stop      # 启动/停止
decotv restart         # 重启
decotv logs            # 跟随日志
decotv update          # 更新镜像并重启容器
decotv https           # 启用/修复 Nginx + HTTPS 证书
decotv backup          # 创建备份
decotv backups         # 列出备份
decotv restore         # 恢复备份(交互输入文件)
decotv uninstall       # 彻底卸载(含数据/配置)
```

---

## 6. HTTPS 说明（必看）

启用自动证书需要：
- 域名 A/AAAA 解析到本机公网 IP（脚本会检测，不通过会停止继续）
- 服务器放行 80/443（**云安全组/防火墙** 都要放行）

脚本会尽力对 **ufw** 自动放行，但云厂商安全组需你自己确认。

---

## 7. 备份与恢复

- 默认备份目录：`/opt/decotv/backups`
- 备份内容：`data/` + `docker-compose.yml` +（如果启用了）Nginx 站点配置

创建备份：

```bash
decotv backup
```

列出备份：

```bash
decotv backups
```

恢复备份（会覆盖当前数据）：

```bash
decotv restore
```

---

## 8. 默认目录与端口

- 程序目录：`/opt/decotv`
- 数据目录：`/opt/decotv/data`
- 备份目录：`/opt/decotv/backups`
- 端口：默认 `3000`（若启用 Nginx，用户一般通过域名访问 80/443）

---

## 9. 卸载

彻底卸载会删除：
- 容器 / 卷
- `/opt/decotv` 全部数据
- Nginx 站点配置
- `/usr/local/bin/decotv`（若已安装快捷命令）

执行：

```bash
decotv uninstall
```
