# Peel 项目结构

Peel 是单一的原生 macOS JSON 编辑器。仓库根目录的 `Package.swift` 定义应用及辅助工具，`make` 提供开发入口。

## 源码模块

| 模块 | 职责 | 依赖 |
| --- | --- | --- |
| `PeelApp` | SwiftUI 界面、窗口生命周期、菜单、快捷键与工作台状态 | `PeelCore`、`PeelEditor` |
| `PeelCore` | JSON 校验与格式化、历史持久化、提取调度和设置模型 | `CSQLite` |
| `PeelEditor` | Scintilla Cocoa 编辑器和 Objective-C++ 桥接 | Scintilla、Lexilla、AppKit |
| `PeelScript` | 在独立 JavaScriptCore 进程执行 JS/JSONPath，通过标准输入输出传递 JSON | 内置 `runtime.js` |
| `CSQLite` | SQLite 系统库声明 | macOS SQLite |

`PeelCore` 的测试通过公开接口验证 JSON、历史、设置及提取行为。`PeelScript` 由 `ExtractionRunner` 启动，每次提取使用独立进程，支持取消和超时终止。

## 应用代码

`Sources/PeelApp/` 按职责组织，同属一个 Swift 模块：

- `App/`：程序入口、应用委托、菜单和全局快捷键。
- `Workspace/`：工作台模型、窗口、布局、工具栏和工作台视图。
- `Editor/`：将原生编辑器接入 SwiftUI。
- `Settings/`：设置窗口、表单和快捷键录制。

`Sources/PeelCore/` 与 `Tests/PeelCoreTests/` 对应分为 `JSON/`、`Extraction/`、`History/` 和 `Settings/`。跨功能的数据契约集中在 `Models.swift`。

## 资源与开发工具

- `Resources/Icons/`：应用图标和 SVG 源文件；`Resources/Licenses/`：随应用分发的许可证。
- `Sources/PeelScript/Resources/runtime.js`：已打包的提取引擎，日常编译直接使用。
- `tools/runtime/`：提取脚本源码与独立的 Node.js 打包依赖。
- `tools/benchmarks/`：`PeelBench` 开发工具及 GUI 性能测量脚本。
- `tools/diagnostics/`：原生编辑器生命周期诊断。
- `scripts/`：构建、测试和第三方源码准备；`patches/`：第三方源码补丁。
- `docs/history/`：历史实施记录；`docs/performance/`：基准原始数据；`docs/troubleshooting/`：问题排查记录。

Scintilla 与 Lexilla 按固定版本和校验和下载到 `Sources/PeelEditor/Vendor/`，由 `PeelEditor` 目标编译。下载目录、`.build/` 和 `build/` 都是忽略的构建产物。

## 产品与数据标识

Swift 包、主程序和应用名称统一为 `Peel`，应用产物为 `build/Peel.app`。为延续已安装版本的数据和偏好，bundle identifier 保持 `com.peel.native`，历史数据库继续位于 `~/Library/Application Support/PeelNative/history.sqlite`，窗口及记录选择偏好键沿用原值。

构建、运行及验证方法见[开发指南](development.md)。
