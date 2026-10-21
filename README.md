# Mic Input Guard · 麦克风输入守护

一个 macOS 菜单栏小工具：直接选择已连接的输入设备，再勾选「固定当前」，系统默认输入被切换后会自动尝试恢复到该设备。

起因是使用 AirPods 作为输出、DJI 接收器作为输入时，希望系统继续使用外接麦克风。默认配置为 `Wireless Mic Rx`；也可以改成其他有线或 USB 麦克风的实际设备名称。

## 功能与边界

- 菜单栏图标跟随实际输入源：Studio Display 显示屏幕、AirPods 显示对应耳机、iPhone 显示手机，其他输入显示麦克风；无输入时显示禁用麦克风。鼠标悬停可查看完整设备名称。
- 菜单栏列出已连接的麦克风，以勾号标记当前输入；点击设备即可切换。
- 「固定当前」可固定任意当前麦克风；手动选择设备会解除原固定。
- 监听默认输入和设备列表变化，每秒兜底检查一次。
- 固定设备断开时保留固定意图，重新连接后尝试恢复。
- 仅在设备断开或连续恢复失败时发送异常通知。
- 不改变音频输出，不录音，不联网。
- 恢复发生在系统切换之后，不能保证瞬间无中断。应用自行指定的输入不受此工具控制。
- 固定时按设备 UID 匹配；命令行按名称选择同名设备时使用首个匹配项。

## 环境

macOS 13 或以上及 Xcode Command Line Tools。设备枚举和切换直接使用 CoreAudio，不再依赖 SwitchAudioSource。

当前只在 Apple Silicon Mac 上完成本地构建和只读命令检查。构建脚本支持选择 `x86_64`，但尚未在 Intel Mac 上验证。

## 配置与构建

1. 在系统声音设置中确认输入设备的准确名称。
2. 编辑 `Resources/config.json`：`preferredInput` 是命令行 `preferred` 别名对应的设备；`aliases` 是可选的命令行简写。配置不需要个人账号、密钥或设备序列号。
3. 在项目目录执行：

```sh
./scripts/build.sh
```

输出为 `build/Mic Input Guard.app`。配置随构建复制进应用，修改后需重新构建。项目使用 Swift 编译器直接打包，不需要 Xcode 工程或第三方 Swift 包。

## 使用

把构建的应用复制到自己的 Applications 文件夹，打开后，通过菜单栏麦克风图标选择输入设备，再勾选「固定当前」。需要异常通知时允许通知权限。

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

`--select` 会实际切换系统输入并解除原固定（包括选择 `preferred`）。使用 `--fix-current` 固定当前设备，`--unfix` 解除固定。切换成功后会启动本应用。原来 Control+Option+M 的快捷指令不包含在本仓库，需要另行创建或更新。

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

旧版 `fixed-input.json` 中的布尔固定设置仍可读取；原先开启固定的用户会继续固定配置的首选设备。首次修改固定状态后保存为包含设备 UID 和名称的新格式。
