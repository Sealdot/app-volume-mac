# 音量卫士 VolumeGuard

一个原生、轻量的 macOS 菜单栏 App，用系统音量上限避免会议后忘记调低音量、打开音乐时突然震耳的情况。

## 已实现

- 默认输出设备的全局音量上限，首次安装默认 20%；
- 前台 App 独立上限，可覆盖默认值；
- 可从运行中列表或 Finder 选择任意 App，并可单独停用规则；
- 音量变化、App 切换、输出设备切换后自动检查并调低；
- 菜单栏状态：保护中、已暂停、已关闭、设备不支持；
- 菜单栏可直接为当前 App 添加或编辑规则；
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

安装到 `/Applications` 并打开：

```bash
./scripts/install.sh
```

首次运行后点击菜单栏扬声器圆形图标打开菜单，再点“打开设置…”。若启用“登录 Mac 时自动启动”，App 会写入当前用户的 `~/Library/LaunchAgents/com.volumeguard.app.plist`；关闭开关会删除该文件。

## 轻量设计

- Core Audio 属性监听驱动，不做高频轮询；
- App 切换使用 `NSWorkspace` 通知；
- 输出设备名称、声道数和可调能力按设备缓存，切换设备时自动失效；
- 业务策略是独立的小型纯 Swift 模块；
- 发布构建静态链接核心模块，单进程常驻；
- 事件历史最多保留 20 条，只存在本机 `UserDefaults`；
- 设置窗口按需创建，关闭后释放完整控件树；
- 设置页使用不可自定义的 macOS 偏好设置工具栏，分为“通用”和“App 规则”；
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

App 规则按“当前前台 App”判断，不会分析哪一个后台进程正在发声。没有匹配 App 规则时仍使用默认上限。这个方案避免申请系统音频录制权限，也避免虚拟音频驱动带来的延迟和兼容风险。

HDMI、AirPlay、部分 USB DAC、Aggregate/Multi-Output Device 可能没有可写的系统音量。这时状态栏会显示“当前设备不支持系统音量保护”，App 不会假装已保护。系统音量百分比也不等于耳边声压或 dBA，本产品用于减少意外高音量，不是医疗器械，不能承诺绝对的听力安全。

完整说明见 [产品规格](docs/PRODUCT_SPEC.md)、[测试计划](docs/TEST_PLAN.md) 和 [技术与开源参考](docs/REFERENCES.md)。

## 工程结构

```text
Sources/VolumeGuardCore   规则、配置、事件模型
Sources/VolumeGuard       AppKit 菜单栏 UI、Core Audio、开机启动
Tests/VolumeGuardCoreChecks  无 XCTest 依赖的核心自检
Resources                 App Bundle 配置
scripts                   构建、安装、测试和性能检查
```

`Package.swift` 便于完整 Xcode 环境使用；本机 Command Line Tools 缺少 `xctest`，因此仓库同时提供不依赖 XCTest 的 `run-checks.sh`。
