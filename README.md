# 音量卫士 VolumeGuard

一个原生、轻量的 macOS 菜单栏 App，在启动、切换 App 或切换输出设备等场景变化时，避免遗留高音量突然震耳，同时尊重用户之后的手动调节。

## 已实现

- 默认输出设备的保护音量，首次安装默认 20%；
- 智能场景保护和严格音量上限两种模式；
- 前台 App 场景规则、逐输出设备规则和设备类型预设；
- 智能模式下，用户按音量键或使用控制中心手动调节后不会立即抢回控制权；
- 从耳机切换到扬声器等其他输出时，可选择立即静音、降至指定值或不处理；
- 可从运行中列表或 Finder 选择任意 App，并可单独停用规则；
- App 启动、前台 App 切换、输出设备切换、睡眠唤醒时自动检查并按需调低；
- 菜单栏状态：保护中、已保留手动音量、已暂停、已关闭、设备不支持；
- 专属蓝绿色盾牌图标，Finder 与“应用程序”中清晰可辨；
- 暂停 15 分钟、1 小时或直到手动恢复；
- 用户级开机启动，不需要管理员权限；
- 本地设置、最近 20 次保护事件和 3 秒通知节流；
- 首次使用引导、当前设备兼容性说明和完整的本地保护历史页；
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

首次运行会显示简短引导，随后打开设置窗口。之后可点击菜单栏扬声器圆形图标打开菜单，再点“设置…”。若启用“登录 Mac 时自动启动”，App 会写入当前用户的 `~/Library/LaunchAgents/com.volumeguard.app.plist`；关闭开关会删除该文件。

## 轻量设计

- Core Audio 属性监听驱动，不做高频轮询；
- App 切换使用 `NSWorkspace` 通知；
- 输出设备名称、声道数和可调能力按设备缓存，切换设备时自动失效；
- 业务策略是独立的小型纯 Swift 模块；
- 发布构建静态链接核心模块，单进程常驻；
- 事件历史最多保留 20 条，只存在本机 `UserDefaults`；
- 设置窗口按需创建，关闭后释放完整控件树；
- 设置页使用不可自定义的 macOS 偏好设置工具栏；“通用”“场景规则”“设备”和“历史”固定等宽等高，并共享分区、卡片与间距规范；
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

保护值按“前台 App 场景规则 → 当前设备规则 → 设备类型预设 → 默认保护值”的顺序选择。场景规则按当前前台 App 判断，不会分析哪一个后台进程正在发声。智能模式把纯音量变化视为用户主动操作，下一次 App、设备、唤醒或设置变化时再执行保护；严格模式会在音量变化后持续执行上限。两种模式都只降不升。

从耳机切换到非耳机输出时，新安装默认立即静音；若目标设备不支持系统静音但支持系统音量，会回退到配置的耳机离开音量。旧版本升级用户默认保持原行为，需自行在“设备”页开启。设备分类来自 Core Audio 传输类型、当前数据源和本机设备名称，只用于选择预设，可以被逐设备规则覆盖。

这个方案避免申请系统音频录制权限，也避免虚拟音频驱动带来的延迟和兼容风险，但无法识别“同一前台 App 未切换、后台媒体突然开始播放”的瞬间，也不能限制音频内容自身的瞬时峰值。

HDMI、AirPlay、部分 USB DAC、Aggregate/Multi-Output Device 可能没有可写的系统音量。设备页会明确显示完整支持、部分支持或不支持；状态栏也不会假装已经保护。系统音量百分比和设备类型预设都不等于耳边声压或 dBA，本产品用于减少意外高音量，不是医疗器械，不能承诺绝对的听力安全。

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
