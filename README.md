# 音量卫士 VolumeGuard

一个原生、轻量的 macOS 菜单栏 App，在启动、切换 App 或切换输出设备等场景变化时，避免遗留高音量突然震耳，同时尊重用户之后的手动调节。

## 已实现

- 默认输出设备的保护音量，首次安装默认 20%；
- 前台 App 独立保护值，可覆盖默认值；
- 用户按音量键或使用控制中心手动调节后，App 不会立即抢回控制权；
- 可从运行中列表或 Finder 选择任意 App，并可单独停用规则；
- App 启动、前台 App 切换、输出设备切换、睡眠唤醒时自动检查并按需调低；
- 菜单栏状态：保护中、已保留手动音量、已暂停、已关闭、设备不支持；
- 专属蓝绿色盾牌图标，Finder 与“应用程序”中清晰可辨；
- 暂停 15 分钟、1 小时或直到手动恢复；
- 用户级开机启动，不需要管理员权限；
- 本地设置、最近 20 次保护事件和 3 秒通知节流；
- 无第三方依赖，不录音，不安装虚拟音频驱动，不使用网络。

## 快速开始

本项目在仅安装 Apple Command Line Tools 的 Mac 上也能构建：

```bash
./scripts/run-checks.sh
./scripts/build-app.sh
open dist/VolumeGuard.app
```

直接启动会打开设置窗口作为反馈；登录启动时只显示菜单栏图标。

安装到 `/Applications` 并打开：

```bash
./scripts/install.sh
```

首次运行会直接打开设置窗口。之后可点击菜单栏扬声器圆形图标打开菜单，再点“设置…”。若启用“登录 Mac 时自动启动”，App 会写入当前用户的 `~/Library/LaunchAgents/com.volumeguard.app.plist`；关闭开关会删除该文件。

## 轻量设计

- Core Audio 属性监听驱动，不做高频轮询；
- App 切换使用 `NSWorkspace` 通知；
- 输出设备名称、声道数和可调能力按设备缓存，切换设备时自动失效；
- 业务策略是独立的小型纯 Swift 模块；
- 发布构建静态链接核心模块，单进程常驻；
- 事件历史最多保留 20 条，只存在本机 `UserDefaults`；
- 设置窗口按需创建，关闭后释放完整控件树；
- 设置页使用不可自定义的 macOS 偏好设置工具栏；“通用”和“App 规则”固定等宽等高，并共享分区、卡片与间距规范；
- 单实例运行；重复打开会唤起现有实例的设置窗口；
- 没有音频采集、均衡器、虚拟设备、数据库、网络 SDK 或分析 SDK。

运行本机性能烟雾测试：

```bash
./scripts/check-performance.sh
```

基线门槛为稳定空闲时 RSS 小于 80 MB；实际结果受系统版本和调试环境影响。

在全程静音并自动恢复原音量/静音状态的前提下，验证真实 Core Audio 钳制：

```bash
./scripts/integration-volume-test.sh
```

## 规则语义与限制

App 规则按“当前前台 App”判断，不会分析哪一个后台进程正在发声。没有匹配规则时使用默认保护值。纯音量变化被视为用户主动操作，因此不会立即压回；下一次 App、设备、唤醒或设置变化时再执行保护。这个方案避免申请系统音频录制权限，也避免虚拟音频驱动带来的延迟和兼容风险，但无法识别“同一前台 App 未切换、后台媒体突然开始播放”的瞬间。

HDMI、AirPlay、部分 USB DAC、Aggregate/Multi-Output Device 可能没有可写的系统音量。这时状态栏会显示“当前设备不支持系统音量保护”，App 不会假装已保护。系统音量百分比也不等于耳边声压或 dBA，本产品用于减少意外高音量，不是医疗器械，不能承诺绝对的听力安全。

完整说明见 [产品规格](docs/PRODUCT_SPEC.md)、[测试计划](docs/TEST_PLAN.md) 和 [技术与开源参考](docs/REFERENCES.md)。

## 安全与隐私

- App 只链接 Apple 系统框架，不申请麦克风、系统音频录制或管理员权限；
- 本地构建启用 Hardened Runtime，但默认临时签名仅用于本机测试；
- 对外分发二进制前必须完成 Developer ID 签名、公证和校验；
- 安全问题请使用 GitHub 私密漏洞报告，不要公开披露利用细节。

详见 [安全策略](SECURITY.md)、[隐私说明](PRIVACY.md) 和 [安全发布清单](docs/RELEASE_SECURITY.md)。

## License

VolumeGuard is available under the [MIT License](LICENSE).

## 工程结构

```text
Sources/VolumeGuardCore   规则、配置、事件模型
Sources/VolumeGuard       AppKit 菜单栏 UI、Core Audio、开机启动
Tests/VolumeGuardCoreChecks  无 XCTest 依赖的核心自检
Resources                 App Bundle 配置
scripts                   构建、安装、测试和性能检查
```

`Package.swift` 便于完整 Xcode 环境使用；本机 Command Line Tools 缺少 `xctest`，因此仓库同时提供不依赖 XCTest 的 `run-checks.sh`。
