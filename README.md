# Mic Input Guard · 麦克风输入守护

一个 macOS 菜单栏小工具：开启固定后，当系统默认输入被切换时，自动尝试恢复到配置的首选麦克风。

起因是使用 AirPods 作为输出、DJI 接收器作为输入时，希望系统继续使用外接麦克风。默认配置为 `Wireless Mic Rx`；也可以改成其他有线或 USB 麦克风的实际设备名称。

## 功能与边界

- 菜单栏查看当前输入，开启或解除固定；默认不固定。
- 监听默认输入和设备列表变化，每秒兜底检查一次。
- 首选设备断开时保留固定意图，重新连接后尝试恢复。
- 仅在设备断开或连续恢复失败时发送异常通知。
- 不改变音频输出，不录音，不联网。
- 恢复发生在系统切换之后，不能保证瞬间无中断。应用自行指定的输入不受此工具控制。
- 按设备名称匹配；同名设备不能精确区分。切换工具同步执行，异常卡住可能影响菜单响应。

## 环境

macOS 13 或以上、Xcode Command Line Tools，以及提供 `SwitchAudioSource` 的 [switchaudio-osx](https://github.com/deweller/switchaudio-osx)。运行时检查 `/opt/homebrew/bin/SwitchAudioSource` 和 `/usr/local/bin/SwitchAudioSource`。

当前只在 Apple Silicon Mac 上完成本地构建和只读命令检查。构建脚本支持选择 `x86_64`，但尚未在 Intel Mac 上验证。

## 配置与构建

1. 在系统声音设置中确认输入设备的准确名称。
2. 编辑 `Resources/config.json`：`preferredInput` 是要固定的设备；`aliases` 是可选的命令行简写。配置不需要个人账号、密钥或设备序列号。
3. 在项目目录执行：

```sh
./scripts/build.sh
```

输出为 `build/Mic Input Guard.app`。配置随构建复制进应用，修改后需重新构建。项目使用 Swift 编译器直接打包，不需要 Xcode 工程或第三方 Swift 包。

## 使用

把构建的应用复制到自己的 Applications 文件夹，打开后，通过菜单栏麦克风图标开启固定。需要异常通知时允许通知权限。

不要同时启用旧版「麦克风提醒」与此应用的固定功能，以免两者控制不同设备。此项目不会替换旧版应用或修改旧版启动项。

此版本不自动安装登录启动项；如需自动运行，可在系统的登录项设置中添加应用。退出会停止本次守护。

命令行示例（在项目根目录）：

```sh
"build/Mic Input Guard.app/Contents/MacOS/MicInputGuard" --help
"build/Mic Input Guard.app/Contents/MacOS/MicInputGuard" --status
"build/Mic Input Guard.app/Contents/MacOS/MicInputGuard" --list
"build/Mic Input Guard.app/Contents/MacOS/MicInputGuard" --select preferred
"build/Mic Input Guard.app/Contents/MacOS/MicInputGuard" --select "其他设备的准确名称"
```

`--select` 会实际切换系统输入：选择首选设备会开启固定；选择其他设备会解除固定。切换成功后会启动本应用。原来 Control+Option+M 的快捷指令不包含在本仓库，需要另行创建或更新。

## 本地数据

固定意图和诊断状态保存在 `~/Library/Application Support/MicInputGuard/` 的 `fixed-input.json` 和 `status.json` 中。它们不在仓库内。应用标识是 `local.MicInputGuard`，与旧版分开。

## 项目结构

```text
Sources/MicInputGuard.swift  应用、菜单栏、CoreAudio 监听及命令行入口
Resources/Info.plist         应用元数据
Resources/config.json        首选设备与命令行别名
scripts/build.sh             编译、打包、本地临时签名
VALIDATION.md                验证范围和人工检查步骤
LICENSE                     MIT 许可证
```

`build/` 是忽略的构建产物。仓库只提交源码、配置和文档。当前签名是本地临时签名，不是 Developer ID 签名，也没有公证；GitHub 发布安装包需另行准备和验证。
