# 技术与开源参考

本项目没有复制第三方代码或引入第三方依赖。方案设计参考了以下一手资料：

- Apple Core Audio `AudioObjectSetPropertyData`：默认输出设备音量通过 HAL 属性读写；
  https://developer.apple.com/documentation/coreaudio/audiohardwareobject/setpropertydata(address:qualifier:data:)
- Apple QA1016：音频设备不一定提供 master 音量，也不保证所有声道都可调；
  https://developer.apple.com/library/archive/qa/qa1016/_index.html
- Apple Service Management：现代 macOS 可用 `SMAppService.mainApp` 注册登录项；本机旧版 SDK 无此编译接口，本 MVP 使用兼容 10.15+ 的用户级 LaunchAgent；
  https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp
- Background Music（GPL-2.0-or-later）：展示了虚拟音频设备可做逐 App 音量，但安装、权限和故障恢复成本不适合轻量 MVP；
  https://github.com/kyleneideck/BackgroundMusic
- FineTune（GPL-3.0）：展示了现代 macOS Process Tap 的逐 App 音量能力，但要求系统音频录制权限和更高系统版本，本项目只参考产品边界；
  https://github.com/ronitsingh10/FineTune
- SimplyCoreAudio（MIT，已归档）：设备枚举、通知与默认设备建模的参考；
  https://github.com/rnine/SimplyCoreAudio
- ISSoundAdditions（MIT）：轻量默认输出音量封装的参考；
  https://github.com/InerziaSoft/ISSoundAdditions

由这些资料得到的产品取舍是：首版只约束默认输出设备的系统音量，不安装 HAL 虚拟驱动，不申请系统音频录制权限；App 条件明确限定为“前台 App 规则”。
