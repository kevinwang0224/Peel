# 原生界面改造

2026-10-08，基点 `fcb3f9a`。

此文件记录 AppKit 版改造。当前界面已进一步迁移为 SwiftUI，见[迁移报告](native-macos-swiftui.md)。

采用 build-macos-apps 插件的 `swiftui-patterns` 中桌面布局、侧栏、菜单和独立设置指导，并按 `appkit-interop` 保留现有原生编辑器及 AppKit 窗口边界。此轮调整表现层，不增加 WebView 或新的 UI 框架。

- 系统 NSToolbar、SF Symbols、快捷键提示和工具栏定制，替代内容顶部的整排文字按钮。
- 使用系统 sidebar 材质，在窗口内部合成；历史列表保持轻量两行，显示图标、标题和更新时间，取消 emoji 固定标记。
- 文档标题与保存状态独立；源码、只读结果、提取控制区层次清晰，窄窗口隐藏辅助提示。
- 编辑器使用低饱和度、明暗分别适配的语法色；修正 Scintilla 忽略系统标签透明度造成的黑色行号和折叠标记，增加文字留白。
- 隐藏并重开结果面板时恢复原分栏比例，同时继续释放隐藏的编辑器。
- 设置独立为应用级唯一窗口；工作台关闭后仍可使用。初始化时等待真实偏好；保存期间阻止重复提交、关闭及退出；失败保留输入并恢复热键。

## 验证

Swift Debug/Release 编译、20 个原生核心测试、Swift format 检查与本机签名验证通过。实际应用确认主界面明暗外观、独立设置布局、格式化/压缩、JSONPath 切换与提取、结果区隐藏/恢复。

性能回归使用 Apple M3 Max / 36 GiB / macOS 27，发行版，1000 条历史（每条 10,000 字节）与约 1 MiB 编辑文档。测量时仅运行一个基准实例。

| 指标 | 实测 |
| --- | --- |
| 外部进程启动至可输入 | 395 ms |
| 插入与同步 AppKit 重绘 P95 | 4.48 ms |
| 主窗口空闲 physical footprint | 92.7 MB |
| 关闭主窗口后 physical footprint | 80.0 MB |
| 相关进程采样峰值 physical footprint | 328.7 MB |

[原始数据](native-macos-performance/2026-10-08-ui-redesign.json)。编辑指标不包含键盘派发与显示器扫描；内存是单次回归结果，不能承诺任何系统状态都低于该值。峰值不适用空闲 100 MB 门槛，macOS 14 尚未实机验证。

首次后台材质测量同时打开了预览实例，空闲读数为 365.6 MB；独立运行同版本为 103.3 MB。将侧栏改为窗口内部材质后的独立回归为上表结果。这些样本同时受到运行环境和系统图形资源回收影响，不据此宣称精确的框架或材质内存降幅。

## Standards

复审最初指出工具栏动作 ID、默认顺序与快捷键分散维护。已集中到 Action 定义并显式传入窗口标识；最终无未解决硬标准或实质维护发现。

## Spec

复审最初发现多个工作台设置窗口可互相覆盖，以及初始化/保存期间的设置生命周期问题。已改为应用级唯一窗口并补齐保护；最终复核通过，无未解决发现。

## Native polish pass (2026-10)

Done: result pane as a native `.inspector` with a draggable result/expression split; segmented `JS | JSONPath`; pane headings removed in favour of one status bar per pane (summary + `Ln/Col`); window subtitle (root type · keys · size) and `isDocumentEdited` for dirty scratch; `.unified` toolbar with sidebar/inspector tracking separators; date-grouped sidebar with `ContentUnavailableView` empty states and ⌫ delete; one-row find bar with match count, Aa/W/.* options, expandable replace, ⌘G/⇧⌘G/⌘E/⌥⌘F; ⌘L go to line; ⌥⌘←/→ collapse/expand all; `.json` drag-and-drop; SF Mono, inactive selection colour, system-red errors with inline annotation, live system-colour updates, adaptive line-number gutter; click-to-record shortcut control in Settings; Window menu Zoom / Bring All to Front.

Second batch: Settings apply immediately (serialized writes; a failed write alerts and rolls the controls back; close/quit stay blocked while a write is in flight); ⌘1/2/3 focus Source/Expression/Result (reveals the inspector if hidden); double-click or context-menu Rename in the sidebar; history loads the next page when the end of the list scrolls into view; whole-window dimming reduced to the editor area while a record is switching; Run uses `NSToolbarItem.style = .prominent` on macOS 26+.

Not done yet: Settings tab toolbar (single form kept), compact Scratch window, improved error wording.

Benchmark after batch two (release, 1 000 × 10 KB, three runs): ready 461–1833 ms (machine under load, high variance), edit-draw P95 7.2–8.5 ms, idle footprint 91–107 MB.
