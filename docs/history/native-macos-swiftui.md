# SwiftUI 界面迁移

2026-10-08，基点 `e25ca3e`。按用户希望使用 SwiftUI 的方向，将工作台与设置的布局、侧栏、工具栏、查找栏和表单改为 SwiftUI。Scintilla Cocoa、SQLite、严格 JSON 处理及独立 JavaScriptCore 提取服务继续使用。

## 界面与桥接

- `WorkspaceView` 用 NavigationSplitView 组织导航，文档标题融入系统窗口标题栏。窗口工具栏由小范围 AppKit 桥接负责，以稳定固定两侧面板开关的位置。
- 文件及 JSON 菜单保留重命名、导出和压缩入口；View菜单提供侧栏与提取区的显示切换。
- `HistorySidebar` 使用原生 sidebar List、searchable 与 Pinned/Recent 分组。
- `ExtractionPanel` 把结果放在右侧上方、表达式放在下方，源码占中央完整高度；隐藏面板销毁两个编辑器，正文/表达式继续由模型持有。
- `FindBar` 是窗口内 SwiftUI 查找替换；首次与重复 ⌘F 都请求聚焦，隐藏提取区后将焦点恢复到原文。
- `SettingsView` 使用分组 Form 与系统 Picker/TextField/Button，设置窗口仍为应用级唯一实例，保留初始化、保存失败、关闭和退出保护。
- `NativeEditor` 是 NSViewRepresentable；Coordinator 仅维护编辑器的增量同步、焦点、粘贴及通知。视图弱引用保存在窗口局部状态中，隐藏编辑器可释放缓冲。
- `WorkspaceViewController` 缩减为 NSHostingController 与少量窗口交互边界。AppKit 继续负责保存后关窗、临时窗口、文件对话框、菜单栏入口与全局热键。

使用 build-macos-apps 插件的 swiftui-patterns、appkit-interop 与 view-refactor 指导，按职责分文件。删除旧 AppKit 侧栏/chrome 实现。

后续界面调整复用现有 Peel 图标，将 AppIcon.icns 随原生应用打包，并设置应用图标。工具栏按历史开关、新建、打开、弹性间距、格式化、压缩、运行、右侧面板开关排列；前三项属于系统导航区，禁用自定义排序。真实应用验证左右面板切换后开关位置稳定，Compact 将 JSON 压成单行、Format 恢复缩进，结果区位于提取区上方。发行版构建与本机签名校验通过；此次未重新测量性能。

## 性能处理

WorkspaceModel 使用 macOS 14 的 Observation，视图按实际读取的状态刷新。正文通过 textRevision 通知编辑器，正文字符串本身不参与 Observation 的新旧相等比较，避免每个键扫描整份 JSON；内部任务、保存版本和回调不参与视图观察。

NSHostingController 不用内容的理想尺寸改变 NSWindow 尺寸；主窗保存位置与大小，隔离测试实例不恢复用户的窗口配置。

保存、加载偏好或关窗后，延迟三秒在后台调用公开的 malloc_zone_pressure_relief，归还分配器已不用的页。该操作不释放任何仍由编辑器/模型持有的缓冲，也不在键盘事件路径中执行。

## 验证

Debug/Release 编译、20 个原生核心测试、Swift format 和本机签名校验通过。实际 SwiftUI 应用验证中文/emoji 粘贴、自动校验、一次撤销/重做、JS 表达式执行、查找替换、首次及重复 ⌘F、隐藏结果后的原文替换、临时窗口保存关闭与主窗历史刷新、独立设置表单及取消。

基准机为 Apple M3 Max / 36 GiB / macOS 27。以下是发行版、1000 条历史（每条 10,000 字节）及约 1 MiB 编辑文档的单次最终回归：

| 指标 | 实测 |
| --- | --- |
| 插入与同步布局/重绘 P95 | 6.32 ms |
| 主窗空闲 physical footprint | 97.6 MB |
| 关闭主窗后 physical footprint | 90.7 MB |

[完整回归原始数据](../performance/2026-10-08-swiftui.json)。该次启动到 ready 为约 2.7 秒；另三次新进程内部 ready 为 631/487/449 ms，完整进程开始到退出为 782/668/595 ms，[启动样本](../performance/2026-10-08-swiftui-startups.json)。早先完整回归的外部 ready 为 606 ms。启动存在波动，目前不能声称所有冷启动都满足一秒目标。

最终另测1000条×1 MiB历史（总正文约1 GB）：内部 ready 693 ms，编辑 P95 8.30 ms，空闲108.8 MB，关窗100.6 MB。[压力回归原始数据](../performance/2026-10-08-swiftui-large-history.json)。这一压力场景的内存仍超过初始100 MB空闲目标，不能把常规样本达标推广到所有历史规模。

编辑指标含实际 Scintilla 插入、同步 SwiftUI/AppKit 布局与重绘，不含键盘派发或显示器扫描。空闲在输入结束35秒后测量；相关进程峰值可高于100 MB，不能将空闲门槛解释为峰值门槛。

本轮最初的 SwiftUI 样本空闲为154 MB；Observation 未绕开正文比较时编辑 P95 曾为54 ms。最终通过正文版本更新及空闲回收改善；不同运行的图形资源和缓存回收也会波动，不把全部差异归因于单项实现改动。

## Standards

复审确认视图、窗口局部状态、设置草稿与编辑器桥接的职责边界合理。最终无未解决标准违反或实质维护发现。

## Spec

复审指出重复 ⌘F 不聚焦，以及隐藏结果后原文替换仍禁用。已通过查找聚焦请求和隐藏时恢复 source 焦点修复，并用真实应用验证。最终复审未发现新的正文保存、设置生命周期或编辑器释放回归。

## 剩余限制

- 最低目标 macOS 14；仅在本机 macOS 27 执行过。
- 启动波动仍未收敛到每次一秒以内。
- 1000条×1 MiB历史的空闲内存超过100 MB目标。
- 全量键盘到屏幕延迟、多个临时窗口压力和超长单行编辑仍需专项验证。
