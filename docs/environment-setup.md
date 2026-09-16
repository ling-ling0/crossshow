# 开发环境记录（M0 要求：暂缺设备/工具时明确记录未验证项）

记录日期：2026-09-14
本机：macOS 26.4，Apple Silicon（arm64），磁盘可用约 392GB。

## 1. 当前工具链状态

| 工具 | 状态 | 说明 |
| --- | --- | --- |
| Homebrew | ✅ 已装（6.0.14） | 包管理器 |
| Go | ✅ 已装（1.27.1，brew） | 后端已开发并通过全部测试；GOPROXY 已固定为 goproxy.cn |
| Flutter / Dart | ✅ 已装（3.47.4 stable，brew cask） | 客户端已开发并通过全部测试；pub 镜像用 pub.flutter-io.cn |
| Xcode | ✅ 已装（26.6）并已切换为系统默认工具链 | macOS .app 构建验证通过；iOS 模拟器运行时未下载（M5 阶段按需装） |
| CocoaPods | 不需要 | Flutter 3.47 已用 Swift Package Manager 管理插件，本项目构建不依赖（将来 iOS 阶段如遇不支持 SPM 的插件再装） |
| Android SDK / JDK | ❌ 待安装 | Android APK 构建必需 |
| Docker | ❌ 未安装 | 本机部署验证需要；deploy/ 配置已就绪 |

### 工具链切换记录（2026-09-14 已完成）

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # 已执行
sudo xcodebuild -runFirstLaunch                                    # 已执行
```

验证：`xcode-select -p` 指向 Xcode.app；`xcodebuild -version` 正常；
`flutter build macos` 不再需要 DEVELOPER_DIR 环境变量。
flutter doctor 的 Xcode 项仍提示两个非阻塞小项：iOS 模拟器运行时未下载、
CocoaPods 未装——均不影响 macOS 交付，按需处理。

## 2. 已完成安装

- Go 1.27.1（Homebrew）。因默认 proxy.golang.org 连接超时，已执行
  `go env -w GOPROXY=https://goproxy.cn,direct` 切换国内镜像（写入 ~/Library/Application Support/go/env，全局生效）。

## 3. 剩余安装清单（由用户自行执行）

```sh
# 1) Go（后端）
brew install go

# 2) Flutter SDK（客户端）
brew install --cask flutter
flutter doctor          # 首次运行会下载 Dart SDK 等组件

# 3) Xcode（macOS 打包必需，约 12GB，只能从 App Store 手动安装）
#    安装后打开一次并接受许可协议，然后：
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept   # 如未在界面接受
xcodebuild -runFirstLaunch

# 4) Android（可选：需要本机构建 APK 时）
#    简易路径：安装 Android Studio（自带 SDK 与 JDK），
#    或命令行安装 android-commandlinetools 后用 sdkmanager 装
#    platform-tools / platforms / build-tools。
```

## 4. 未验证项清单（按开发文档 M0 验收要求记录）

以下事项在对应工具就绪前**均未验证**，不得视为已完成：

- [x] Go 服务编译与单元/集成测试运行（19 个测试函数 / 59 场景，含 -race，全部通过）
- [x] 服务端冒烟验证：启动 → 创建 16 周重复系列 → 幂等重放 → 范围查询 → 批量预览/提交 → 重启持久化
- [x] Flutter 工程创建、`flutter analyze` 零问题、16 个客户端测试通过
- [x] 客户端 ↔ 服务端真实联调：Flutter Repository 直连本地 Go 服务，完成
      创建系列 → 查询 → 单次修改 → 409 冲突 → 批量预览/提交 → 批量删除全流程
- [x] macOS `.app` 打包与安装 ✅（2026-09-15：release 版 45MB 已安装至
      /Applications/CrossShow.app 并验证启动；DMG 安装镜像：桌面 CrossShow-0.1.0.dmg；
      注意：本地构建，无开发者签名，从网络传到其他 Mac 会触发 Gatekeeper 提示）
- [ ] Android 空应用 APK 构建与安装验证 ✅（2026-09-15：release APK 53MB；已配镜像与
      usesCleartextTraffic；APK 副本：桌面 CrossShow.apk）
- [ ] 真机/桌面与服务器连通性（含 IP + HTTPS 证书信任、平台网络策略；文档 9.2）
- [ ] 阿里云服务器环境核实：CPU 架构、发行版、内存、Docker、安全组端口（文档 9.1）
- [ ] 备份恢复演练（部署阶段执行，文档 9.3）

## 5. 环境就绪后的动作

Flutter 装好后运行 `flutter doctor` 确认（Flutter 项为 ✓ 即可），然后开始客户端开发；
Xcode / Android SDK 就绪后补 M0 的双平台空应用构建验证。
