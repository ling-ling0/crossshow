# CrossShow

个人时间安排应用：Flutter 客户端（首版 macOS / Android）+ Go 后端 + SQLite，部署于阿里云服务器，多端同步。开发依据见 [docs/development-plan-v0.1.md](docs/development-plan-v0.1.md)。

## 目录结构

```text
crossshow/
  apps/client/      # Flutter 客户端（首版 macOS / Android）
  server/           # Go API 服务（cmd/api + internal/* + migrations）
  api/openapi.yaml  # API 契约
  deploy/           # Dockerfile、docker-compose、配置示例、备份脚本
  docs/             # 开发、部署、环境与使用文档
```

## 状态

- M0 进行中：目录与部署/契约/迁移等不依赖工具链的产物已就绪；Go、Flutter 代码待开发环境安装后实施。
- 环境安装清单与未验证项：[docs/environment-setup.md](docs/environment-setup.md)。

## 快速部署（服务器侧）

```sh
cp deploy/config.example.env deploy/.env   # 修改端口与时区
docker compose -f deploy/docker-compose.yml up -d --build
crontab: 30 3 * * * deploy/backup.sh /var/lib/crossshow/data /var/lib/crossshow/backups
```
