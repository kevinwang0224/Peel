# Peel

[English README](README.md)

**Peel** 是一款原生 macOS JSON 编辑器，使用 SwiftUI、AppKit、Scintilla Cocoa、SQLite 和 JavaScriptCore 构建。支持 macOS 14+ 和 Apple Silicon。

```bash
make run
```

## 功能概览

- 基于 **Scintilla** 的编辑：语法高亮、校验、常用快捷键
- 粘贴合法 JSON 时**自动格式化**；非 JSON 保留原文
- 通过 JavaScript 或 **JSONPath** 提取；结果字符串包含合法 JSON 对象或数组时，自动格式化并高亮
- **JSON 字符串连续访问**：自动识别字符串中的 JSON 对象或数组，支持 `data.value.msg[0].clazzId` 逐级补全和提取
- **历史侧栏**：新建、搜索、固定、重命名、删除，编辑自动保存
- **导入 / 导出**：打开与导出 JSON 文件
- **主题**：跟随系统 / 浅色 / 深色，应用图标（`{ ... }`）随之切换

## 仓库结构

| 路径 | 说明 |
|------|------|
| [`Package.swift`](Package.swift) | Swift 包及可执行产物定义 |
| [`Sources/`](Sources/) | 应用、JSON 核心、原生编辑器及提取进程 |
| [`Tests/`](Tests/) | 按功能组织的原生核心测试 |
| [`Resources/`](Resources/) | 应用图标、源图和许可证 |
| [`scripts/`](scripts/) | 构建、测试和依赖准备脚本 |
| [`tools/`](tools/) | 性能测量、编辑器诊断及提取脚本打包工具 |
| [`docs/`](docs/) | 开发指南、架构说明及历史记录 |

模块职责见[架构说明](docs/architecture.md)，构建环境、数据迁移与验证方法见[开发指南](docs/development.md)。

## 常用根目录脚本

在仓库根目录执行。构建和测试需要 Xcode 及 macOS SDK；只有重新打包提取脚本时才需要 Node.js。

| 命令 | 用途 |
|------|------|
| `make build` | 构建 `build/Peel.app` |
| `make run` | 构建并打开 Peel |
| `make test` | 运行原生测试 |
| `make benchmark` | 构建并测量 Peel 的性能 |
| `make runtime` | 重新打包提取脚本，需要 Node.js |

执行 `make` 可查看全部命令。可选的 Node.js 工具单独放在 `tools/runtime/`，日常构建和测试使用已提交的提取脚本产物。

## 应用图标

SVG 源文件在 `Resources/Icons/Source/`（`AppIcon.svg` 为深色，`AppIconLight.svg` 为浅色）。应用按当前外观切换 `AppIcon.icns` / `AppIconLight.icns`。
