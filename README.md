# 豆包输入法语音快捷切换

[![macOS](https://img.shields.io/badge/macOS-automation-111827)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-helper-orange)](https://www.swift.org/)
[![Keyboard Maestro](https://img.shields.io/badge/Keyboard%20Maestro-supported-blue)](https://www.keyboardmaestro.com/)

这个小工具配合 Keyboard Maestro 使用：按一次快捷键切到豆包输入法并打开语音输入，再按一次快捷键结束语音输入并切回原来的输入法。

它还会把每次豆包语音输入出来的文字自动记录到桌面的 Markdown 文件里，形成一个本地“语音输入历史记录板”。新的记录会写在文件最上面，打开就能看到最新内容。

当前默认快捷键是 `Command + \`。你也可以在 Keyboard Maestro 里改成自己习惯的组合。

## 适合什么场景

- 平时用双拼、系统拼音或其他输入法打字
- 需要临时按一个快捷键切到豆包语音输入
- 语音结束后希望自动回到原来的输入法
- 希望保留豆包语音输入历史，之后可以搜索、复制和找回
- 不想手动点输入法菜单或反复切换系统输入源

## 仓库内容

```text
.
├── src/DoubaoVoiceToggle.swift
├── install.sh
└── keyboard-maestro/DoubaoVoiceToggle-CmdBackslash.kmmacros
```

## 当前逻辑

每次触发时，脚本先读取当前输入法：

1. 如果当前不是豆包输入法：
   - 记录当前输入法，作为结束后要恢复的输入法。
   - 记录当前焦点输入框的原始内容。
   - 启动一个后台记录器，监听这个输入框的原生 `AXValueChanged` 变化。
   - 切换到豆包输入法。
   - 等 `0.3` 秒，让豆包输入法完成切换。
   - 模拟按下豆包内部语音快捷键：`右 Command + 右 Option`。

2. 如果当前已经是豆包输入法：
   - 模拟按下 `右 Command + 右 Option`，结束豆包语音输入。
   - 通知后台记录器收尾。
   - 立刻切回之前记录的输入法。
   - 后台记录器继续短暂观察输入框，等豆包/AI 润色后的文字真正落地。
   - 记录器计算“原始内容 -> 最终内容”的新增文本。
   - 把新增文本写入桌面 Markdown 记录文件顶部。

连续触发时，下一轮开始前会给上一轮记录器最多约 `1` 秒的收尾时间，并且上一轮不会再误删下一轮的会话标记。这个等待只影响记录器收尾，不会让“切回原输入法”变慢。

状态文件只负责记录“结束后恢复到哪个输入法”，不负责判断启动还是结束。判断只看当前输入法是不是豆包。

## 语音历史记录

记录文件默认在桌面：

```text
~/Desktop/豆包语音输入记录.md
```

新的记录会插到标题下面、旧记录往下排。格式示例：

```md
# 豆包语音输入记录

## 2026-06-26 03:39:08

App：TextEdit（com.apple.TextEdit）

这是一段通过豆包语音输入生成的示例文本。

---
```

记录方式不是抓网络包，也不是读剪贴板。脚本会在语音开始前读取当前输入框内容，在语音结束时读取最终内容，然后把新增文本写入历史文件。

这个方式依赖 macOS 辅助功能接口。大多数原生文本框和一部分 Electron / Web 输入框可用；如果某个 App 的输入框不暴露 `AXValue`，那次语音仍然可以正常输入，只是不会被记录。

## 前置条件

- macOS
- 已安装豆包输入法
- 已安装 Keyboard Maestro
- 已安装 Xcode Command Line Tools
- 豆包输入法里已经把语音输入快捷键设置为 `右 Command + 右 Option`

如果没有 Xcode Command Line Tools，可以执行：

```zsh
xcode-select --install
```

## 安装脚本

在仓库目录执行：

```zsh
./install.sh
```

安装后 helper 会放到：

```text
~/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle
```

Keyboard Maestro 宏会调用这个 helper。

## Keyboard Maestro 配置

方式一：导入现成宏

导入这个文件：

```text
keyboard-maestro/DoubaoVoiceToggle-CmdBackslash.kmmacros
```

这个宏会执行：

```zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle"
```

方式二：手动创建宏

1. 新建一个 Keyboard Maestro Macro。
2. Trigger 选择 Hot Key Trigger。
3. 快捷键设置为你想用的组合，例如 `Command + \`。
4. Action 选择 Execute Shell Script。
5. 脚本内容填：

```zsh
#!/bin/zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle"
```

## 打开豆包输入法设置

豆包输入法设置页可以用下面命令打开：

```zsh
open "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app"
```

建议在设置里确认：

- 语音输入快捷键是 `右 Command + 右 Option`
- 麦克风不要用自动检测时，可以手动选固定麦克风
- macOS 麦克风权限已经允许豆包输入法

## macOS 权限

如果脚本不能模拟按键，需要检查系统设置里的辅助功能权限：

- Keyboard Maestro
- Keyboard Maestro Engine
- 这个 helper 本身，如果系统单独提示过

如果语音输入能用，但历史记录没有写入，也需要检查辅助功能权限。记录器通过 macOS Accessibility 读取当前输入框变化。

如果豆包没有声音输入，需要检查麦克风权限：

- 系统设置 -> 隐私与安全性 -> 麦克风
- 确认豆包输入法已允许

## 可调参数

源码在：

```text
src/DoubaoVoiceToggle.swift
```

目前启动等待时间是 `0.3` 秒：

```swift
private let doubaoVoiceStartDelay: useconds_t = 300_000
```

如果偶发切到豆包但语音框没出来，可以把它调大，例如 `500_000` 表示 `0.5` 秒。
