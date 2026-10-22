# 掌上待办应用图标 · hi v2

掌心图案由勾改为蓝色手写小写 `hi`，延续原手掌造型和暖肤色。保留透明背景，以独立手掌轮廓作为桌面应用图标。

## 文件

- `HandTodo-1024.png`：1024 × 1024 像素 RGBA 主图。
- `HandTodo.icns`：macOS 应用图标，包含 16、32、128、256、512 pt 的 1× / 2× 表示，最高 1024 × 1024 像素。
- `HandTodo.iconset/`：macOS 图标源尺寸，共 10 张 PNG。
- `HandTodo.ico`：Windows 多尺寸图标，包含 16、20、24、30、32、36、40、48、60、64、72、80、96、128、256 像素图像。
- `windows/`：Windows 各尺寸 PNG。
- `validation.json`：尺寸、透明通道和容器结构核验结果。
- `generation-prompt.txt`：内置 imagegen 使用的完整编辑提示词。

图标文件适配项目当前的 macOS AppKit 与 Windows WPF 桌面应用分发形式。本次交付为图标素材；不包含应用安装包或构建配置变更。

## 规范参考

- [Apple：传统 macOS 高分辨率图标与 iconset](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html)
- [Microsoft：Windows 应用图标尺寸](https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction)

16–24 像素下应以手掌轮廓作为主要识别特征；手写字在较大的 Finder、Dock、桌面和开始菜单图标中更清楚。
