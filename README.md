# 豆包语音快捷切换

[![macOS](https://img.shields.io/badge/macOS-automation-111827)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-helper-orange)](https://www.swift.org/)
[![Keyboard Maestro](https://img.shields.io/badge/Keyboard%20Maestro-supported-blue)](https://www.keyboardmaestro.com/)
[![Status](https://img.shields.io/badge/status-personal%20daily%20tool-22c55e)](#)

一个给 Mac 用的豆包输入法语音助手。

按一次快捷键：切到豆包输入法，打开语音输入。

再按一次快捷键：结束语音输入，切回原来的输入法。

同时它会把语音输入出来的文字保存到桌面 Markdown，像一个轻量历史记录。

## 核心功能

- 一键切到豆包输入法并触发语音输入。
- 再按一次，结束语音并切回原输入法。
- 语音输入前，如果系统正在播放音乐，会先暂停。
- 语音结束后，只在原本就是播放状态时恢复播放。
- 自动记录本次语音写入的文字。
- 新记录写在文件最上方，不用翻到底。
- 内部触发豆包语音使用 `右 Command + 右 Option`，两个键同时按下，不插入额外间隔。

记录文件在：

```text
~/Desktop/豆包语音输入记录.md
```

## 工作流程

启动语音：

1. 记住当前输入法。
2. 检查系统 Now Playing 状态，必要时暂停音乐。
3. 启动文字记录器，盯住当前输入框。
4. 切换到豆包输入法。
5. 等待短暂启动间隔。
6. 触发豆包内部语音快捷键。

结束语音：

1. 触发豆包内部语音快捷键，结束语音。
2. 发送记录器停止信号。
3. 立刻切回原输入法。
4. 按启动前的状态恢复音乐。
5. 把新增文字写入桌面记录。

这版不做额外执行锁，也不扫豆包语音小窗。逻辑目标是短、直、少干扰。

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

安装 helper：

```zsh
./install.sh
```

安装后位置：

```text
~/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle
```

## Keyboard Maestro 配置

仓库里带了一个宏：

```text
keyboard-maestro/DoubaoVoiceToggle-CmdBackslash.kmmacros
```

默认外部快捷键是：

```text
Command + \
```

也可以自己建 Keyboard Maestro 宏，Shell 内容填：

```zsh
#!/bin/zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle"
```

## 豆包输入法配置

打开豆包输入法设置：

```zsh
open "/Library/Input Methods/DoubaoIme.app/Contents/DoubaoImeSettings.app"
```

确认：

- 语音快捷键：`右 Command + 右 Option`
- 麦克风：选固定设备，不要让它乱跳

## macOS 权限

需要辅助功能权限：

- Keyboard Maestro
- Keyboard Maestro Engine
- 这个 helper，如果系统单独提示过

路径：

```text
系统设置 -> 隐私与安全性 -> 辅助功能
```

如果语音没声音，检查麦克风权限：

```text
系统设置 -> 隐私与安全性 -> 麦克风
```

## 常用命令

查看当前输入法：

```zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle" current
```

检查辅助功能权限：

```zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle" access
```

重置状态：

```zsh
"$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle" reset
```

看日志：

```zsh
tail -f "$HOME/Library/Application Support/DoubaoVoiceToggle/doubao-voice-toggle.log"
```

日志只保留少量状态和错误信息，并限制大小，避免无限增长。

## 可调参数

源码：

```text
src/DoubaoVoiceToggle.swift
```

最常改的是启动等待：

```swift
private let doubaoVoiceStartDelay: TimeInterval = 0.3
```

如果豆包启动语音偶尔慢，可以试 `0.5`；如果机器反应很快，可以继续用 `0.3`。

## 说明

这是个人日用工具，不是通用输入法框架。它主要解决一个很具体的问题：

> 保持平时正常使用双拼/系统输入法，需要语音时临时切到豆包，结束后自动回去，并留下文字记录。

如果你的豆包输入法版本、内部快捷键或 macOS 权限状态不同，需要先按上面的配置对齐。
