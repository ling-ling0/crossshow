# 部署手册（阿里云 ECS 直连二进制方案）

服务器实测环境（2026-09-15）：x86_64 · Ubuntu 24.04.4 · 1.6GB 内存（含 2GB swap）· Docker 29.5.2。

## ✅ 部署状态（2026-09-15 完成上线）

- 服务地址：`http://<服务器IP>:8080`（外网已验证可达）
- 部署方式：本机交叉编译 linux/amd64 → scp → systemd（`crossshow-api.service`，已开机自启）
- 数据目录：`/opt/crossshow/data`；备份：`/opt/crossshow/backups`（每日 03:30 cron，保留 14 份，已配置）
- 安全组：TCP 8080 已放行
- 外网端到端验证：healthz ✓、config ✓、远程创建重复事件 ✓

方案说明：开发文档 9.1 建议 Compose 容器部署，但 1.6GB 内存机器上在容器内
编译 Go + 纯 Go SQLite 驱动峰值内存偏高，故采用更稳的 **本机交叉编译 →
scp 单文件 → systemd 托管** 方案。`docker-compose.yml` 保留，未来升级内存
后可无缝切换（数据目录同构：`/opt/crossshow/data`）。

## 一次性部署（本机执行）

```sh
# 1. 交叉编译（本机，产物 11MB 静态二进制）
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags="-s -w" -o crossshow-api ./cmd/api

# 2. 上传（把 SERVER 换成服务器公网 IP）
scp crossshow-api root@$SERVER:/opt/crossshow/crossshow-api
scp deploy/crossshow-api.service root@$SERVER:/etc/systemd/system/
scp deploy/backup.sh root@$SERVER:/opt/crossshow/backup.sh

# 若 /opt/crossshow 不存在，先 ssh 上去执行：
#   mkdir -p /opt/crossshow/data /opt/crossshow/backups

# 3. 启动（服务器上执行）
sudo systemctl daemon-reload
sudo systemctl enable --now crossshow-api
sudo systemctl status crossshow-api   # 应为 active (running)

# 4. 验证
curl http://127.0.0.1:8080/healthz    # {"status":"ok"}
```

## 安全组（阿里云控制台）

放行 TCP **8080**（或自定义端口，同步改 service 文件的
`CROSSSHOW_LISTEN_ADDR`）。SSH 22 端口保持仅对自己的 IP 开放。

> ⚠️ 已知限制（开发文档 9.2）：首版无鉴权，公网上任何知道 IP:端口的人
> 都能读写日程。HTTPS 只保护传输不提供授权。缓解：用非常规端口 + 不外传
> IP；长期方案：域名 + 反向代理 TLS，或换内网穿透/组网方案（后续再议）。

## 每日备份（服务器上执行一次）

```sh
# 安装 sqlite3（备份脚本依赖）
sudo apt update && sudo apt install -y sqlite3

# 每天 03:30 备份，保留 14 份
crontab -e
# 加入一行：
30 3 * * * /opt/crossshow/backup.sh /opt/crossshow/data/crossshow.db /opt/crossshow/backups 14 >> /var/log/crossshow-backup.log 2>&1
```

**恢复演练**（正式使用前至少做一次，文档 9.3）：

```sh
sudo systemctl stop crossshow-api
cp /opt/crossshow/data/crossshow.db /tmp/broken.db        # 保存当前库
cp /opt/crossshow/backups/crossshow-<某次>.db /opt/crossshow/data/crossshow.db
sqlite3 /opt/crossshow/data/crossshow.db "PRAGMA integrity_check;"   # 应输出 ok
sudo systemctl start crossshow-api
curl http://127.0.0.1:8080/api/v1/events?from=2026-01-01\&to=2026-04-01  # 核对事件数量
```

## 客户端连接

两台设备的 CrossShow 应用设置页填 `http://<服务器IP>:8080`。
真机需验证：Android 明文 HTTP 流量策略（`usesCleartextTraffic`）、
macOS App Sandbox 网络权限（首次构建已确认可用本机连接）。

## 升级服务

```sh
# 本机重新编译 → scp 覆盖 → 服务器重启服务
sudo systemctl restart crossshow-api
# schema 兼容性由迁移机制保证；不兼容时应用启动会明确报错（文档 10）
```
