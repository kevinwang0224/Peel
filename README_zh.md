# Peel

[English README](README.md)

**Peel** 是一款 macOS 上的 JSON 格式化与编辑工具。使用 SwiftUI、AppKit 编辑器/窗口桥接、Scintilla Cocoa、SQLite 和独立 JavaScriptCore 提取进程构建，面向低内存和快速启动。要求 macOS 14+、Apple Silicon 和 Xcode，运行不需要 WebView 或 Node。详见 [原生版本说明](apps/native-macos/README.md)。

```bash
bash apps/native-macos/scripts/build.sh
open "apps/native-macos/build/Peel Native.app"
```

## 功能概览

- 基于 **Scintilla** 的编辑：语法高亮、校验、常用快捷键
- 粘贴合法 JSON 时**自动格式化**；非 JSON 保留原文
- 通过 JavaScript 或 **JSONPath** 提取
- **历史侧栏**：新建、搜索、固定、重命名、删除，编辑自动保存
- **导入 / 导出**：打开与导出 JSON 文件
- **主题**：跟随系统 / 浅色 / 深色，应用图标（`{ ... }`）随之切换

## 仓库结构

| 路径 | 说明 |
|------|------|
| [`apps/native-macos/`](apps/native-macos/) | 原生 macOS 应用（Swift 6、SwiftUI、AppKit、Scintilla） |
| [`packages/shared/`](packages/shared/) | **与平台无关** 的 JSON 工具、提取逻辑、类型与历史相关辅助（`@peel/shared`） |
| `apps/extension/` | 预留的**浏览器扩展**工作区，后续只复用 `@peel/shared` |

## 常用根目录脚本

先执行 `npm install`：

| 命令 | 用途 |
|------|------|
| `npm run build` / `npm run native:build` | 构建原生应用 |
| `npm run dev:native` | 构建并打开原生应用 |
| `npm run native:test` | 运行原生测试 |
| `npm run build:shared` | 构建 `@peel/shared` |
| `npm run lint` / `test` / `typecheck` | 在定义了对应脚本的工作区中运行 |

## 应用图标

SVG 源文件在 `apps/native-macos/Resources/IconSource/`（`AppIcon.svg` 为深色，`AppIconLight.svg` 为浅色）。应用按当前外观切换 `AppIcon.icns` / `AppIconLight.icns`。
