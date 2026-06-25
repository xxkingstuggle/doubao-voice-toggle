# 豆包输入法语音快捷切换

这个小工具配合 Keyboard Maestro 使用：按一次快捷键切到豆包输入法并打开语音输入，再按一次快捷键结束语音输入并切回原来的输入法。

当前默认快捷键是 `Command + \`。你也可以在 Keyboard Maestro 里改成自己习惯的组合。

## 当前逻辑

每次触发时，脚本先读取当前输入法：

1. 如果当前不是豆包输入法：
   - 记录当前输入法，作为结束后要恢复的输入法。
   - 切换到豆包输入法。
   - 等 `0.3` 秒，让豆包输入法完成切换。
   - 模拟按下豆包内部语音快捷键：`右 Command + 右 Option`。

2. 如果当前已经是豆包输入法：
   - 模拟按下 `右 Command + 右 Option`，结束豆包语音输入。
   - 立刻切回之前记录的输入法。

状态文件只负责记录“结束后恢复到哪个输入法”，不负责判断启动还是结束。判断只看当前输入法是不是豆包。

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

