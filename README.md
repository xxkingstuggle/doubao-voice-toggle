# 豆包语音快捷切换

[![macOS](https://img.shields.io/badge/macOS-automation-111827)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-helper-orange)](https://www.swift.org/)
[![Keyboard Maestro](https://img.shields.io/badge/Keyboard%20Maestro-supported-blue)](https://www.keyboardmaestro.com/)

一个 Mac 小工具。

按一次快捷键：切到豆包输入法，打开语音输入。
再按一次：结束语音输入，切回原来的输入法。

顺手做三件事：

- 暂停正在播放的音乐/视频，结束后恢复。
- 把豆包语音输入结果记到桌面 Markdown。
- 新记录放最上面，不用翻到底。

## 它怎么工作

启动时：

1. 记住当前输入法。
2. 如果有音乐/视频在播，先暂停。
3. 启动记录器，盯住当前输入框。
4. 切到豆包输入法。
5. 按豆包内部语音快捷键：`右 Command + 右 Option`。
6. 检查黑色胶囊语音小窗有没有出现；没出现就自动再按一次。

结束时：

1. 再按一次豆包内部语音快捷键，结束语音。
2. 立刻切回原输入法。
3. 恢复刚才暂停的音乐/视频。
4. 把新增文字写进桌面记录。

记录文件：

```text
~/Desktop/豆包语音输入记录.md
```

## 安装

需要：

- macOS
- 豆包输入法
- Keyboard Maestro
- Xcode Command Line Tools

没有 Command Line Tools 就先装：

```zsh
xcode-select --install
```

然后在仓库目录执行：

```zsh
./install.sh
```

helper 会安装到：

```text
~/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle
```

## Keyboard Maestro

导入宏：

```text
keyboard-maestro/DoubaoVoiceToggle-CmdBackslash.kmmacros
```

默认快捷键是：

```text
Command + \
```

你也可以自己建一个宏，Shell 内容填：

```zsh
#!/bin/zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle"
```

## 豆包输入法设置

豆包设置可以这样打开：

```zsh
open "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app"
```

确认两件事：

- 语音快捷键：`右 Command + 右 Option`
- 麦克风：选你要用的固定麦克风

## 权限

需要 macOS 辅助功能权限：

- Keyboard Maestro
- Keyboard Maestro Engine
- 这个 helper，如果系统单独提示过

语音没声音，就看麦克风权限：

```text
系统设置 -> 隐私与安全性 -> 麦克风
```

## 排查

看日志：

```zsh
tail -f "$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle.log"
```

看豆包语音小窗：

```zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle" voice-windows
```

正常录音时，`voicePanelCandidates` 应该大于 `0`。
它识别的是黑色胶囊、蓝色波浪那个小窗，不是豆包常驻窗口。

## 可调参数

源码在：

```text
src/DoubaoVoiceToggle.swift
```

常改的是启动等待：

```swift
private let doubaoVoiceStartDelay: TimeInterval = 0.3
```

如果豆包偶尔慢，可以调到 `0.5`。
