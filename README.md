# CrossShow

个人时间安排应用：Flutter 客户端（macOS / Android）+ Go 后端 + SQLite，部署于自有服务器，多端同步。开发依据与设计细节见 [docs/development-plan-v0.1.md](docs/development-plan-v0.1.md)。

## 功能特性

- **事件**：普通（起止时间）、全天（起止日期，不含式结束）、跨天、待办（无固定时间，v0.2）
- **重复**：每天 / 工作日 / 每周 / 每双周，有限次数（1–520），月末与闰日自动规范化
- **批量修改**："仅本次 / 本次及以后"；进行中的事件可参与批量，已结束的记录受保护；预览令牌 + 事务提交
- **同步**：打开/回前台自动同步 + 手动刷新；乐观锁版本冲突提示；幂等写入防重复创建
- **视图**：桌面周网格 / 手机当天列表与单日时间轴，重叠等宽分列，跨天延续标记
- **本地化**：日历时区固定 Asia/Shanghai；法定假日与周末着色（假日数据可编辑，见 `apps/client/assets/holidays.json`）
- **隐私模式**：一键隐藏时间块文字，只保留色块

## 目录结构

```text
apps/client/      # Flutter 客户端（macOS / Android）
server/           # Go API 服务（cmd/api + internal/* + migrations 内嵌迁移）
api/openapi.yaml  # API 契约
deploy/           # systemd 服务、Docker Compose、备份脚本
docs/             # 开发计划、部署手册、环境记录
```

## 构建

```sh
# macOS（产物 build/macos/Build/Products/Release/）
cd apps/client && flutter build macos --release

# Android APK（产物 build/app/outputs/flutter-apk/）
cd apps/client && flutter build apk --release

# 服务端（Linux x86_64 单文件）
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o crossshow-api ./cmd/api
```

依赖：Flutter SDK、Xcode（macOS 打包）、Android SDK（APK）、Go 1.25+。版本以各端工程文件锁定的为准。

## 服务端部署

单文件二进制 + systemd 方案，步骤与备份/恢复演练见 [docs/deployment.md](docs/deployment.md)；`deploy/` 另含 Docker Compose 与每日备份脚本。配置全部走环境变量（监听地址、数据路径、默认时区），不写入客户端代码。

> ⚠️ 首版无账号体系：服务端不对请求做身份鉴别，HTTPS 只保护传输。请部署在可信网络或自行加反代鉴权。

## 测试

```sh
cd server && go test ./...            # 后端：规则 + 真实临时 SQLite 集成测试
cd apps/client && flutter test        # 客户端：布局算法 / 模型 / 仓库 / 联调
```

## 发布说明

安装包（.dmg / .apk）通过 **GitHub Releases** 分发，不提交进仓库（`.gitignore` 已排除 `packed/`）。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
