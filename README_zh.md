# Peel

[English README](README.md)

**Peel** 是一款 JSON 格式化与编辑工具。当前主线新增原生 macOS 版本，使用 Swift、AppKit、Scintilla Cocoa、SQLite 和独立 JavaScriptCore 提取进程，面向低内存和快速启动；旧 Electron 工作区保留用于迁移对照。

原生版构建与运行：

```bash
bash apps/native-macos/scripts/build.sh
open "apps/native-macos/build/Peel Native.app"
```

要求 macOS 14+、Apple Silicon 和 Xcode。原生运行不需要 Electron、WebView 或 Node；原生构建也可直接使用仓库内的 JS bundle。详见 [原生版本说明](apps/native-macos/README.md)。

下文保留旧 Electron 版本说明；启动旧版使用 `npm run dev:electron`。

## 功能概览

- 基于 **Monaco** 的编辑：语法高亮、校验、常用快捷键  
- 粘贴时若内容为合法 **JSON 会自动排版**；非 JSON 则保留原文  
- **提取**：支持内嵌 **JavaScript** 与 **JSONPath**（在后台线程执行，避免阻塞界面）  
- **历史侧栏**：新建、搜索、固定、重命名、删除；编辑会**自动保存**到当前记录  
- **导入/导出**：打开 JSON 文件、导出；剪贴板通过应用壳层读写  
- **主题**：跟随系统、浅色或深色  
- **桌面端**：系统文件对话框与菜单集成（Electron）

## 仓库结构

| 路径 | 说明 |
|------|------|
| [`apps/desktop/`](apps/desktop/) | 当前 **Electron** 桌面应用（React、TypeScript、Vite、Tailwind、shadcn/ui、Monaco） |
| [`packages/shared/`](packages/shared/) | **与平台无关** 的 JSON 工具、提取逻辑、类型与历史相关辅助（`@peel/shared`） |
| `apps/extension/` | 预留的**浏览器扩展**工作区，后续只复用 `@peel/shared` |

界面仅通过预加载层暴露的 **`window.peel`** 小接口访问系统能力，不直接在渲染进程调用 Node 或 Electron API。

## 环境要求

- 推荐 **Node.js 20+**（与当前 Electron / Vite 工具链一致）  
- 使用 **npm**（根目录为 npm workspaces）

## 快速开始

```bash
git clone <你的仓库地址> peel
cd peel
npm install
```

### 开发运行桌面端

```bash
npm run dev:electron
```

将启动 `@peel/desktop` 工作区（electron-vite）。

### 其他常用根目录脚本

| 命令 | 作用 |
|------|------|
| `npm run build:shared` | 构建 `@peel/shared` |
| `npm run lint` | 为各子包运行 lint（若定义了 `lint`） |
| `npm run test` | 在各子包运行测试 |
| `npm run typecheck` | 各子包类型检查 |
| `npm run build` | 构建原生 macOS 应用 |
| `npm run native:test` | 运行原生核心行为测试 |

### 仅桌面端

在仓库根目录：

```bash
npm run test -w @peel/desktop
npm run build -w @peel/desktop
```

`@peel/desktop` 的 `build` 会先构建 `@peel/shared`、做 typecheck 与测试，再打包 Electron 应用。

**macOS 安装包/归档**（详见 `apps/desktop/package.json`）：

```bash
npm run build:mac -w @peel/desktop
```

将生成 DMG 与 ZIP（具体见 `apps/desktop/electron-builder.yml`）。

更细的桌面端说明见 [`apps/desktop/README.md`](apps/desktop/README.md)。

## 技术栈（桌面端）

- [Electron](https://www.electronjs.org/) — 桌面壳  
- [React](https://react.dev/) + [TypeScript](https://www.typescriptlang.org/)  
- [Vite](https://vitejs.dev/) + [electron-vite](https://electron-vite.org/)  
- [Tailwind CSS](https://tailwindcss.com/) + [shadcn/ui](https://ui.shadcn.com/)（Radix 基础组件）  
- [Monaco Editor](https://github.com/microsoft/monaco-editor)  
- 共享逻辑：[jsonc-parser](https://github.com/microsoft/node-jsonc-parser)、[jsonpath-plus](https://github.com/JSONPath-Plus/JSONPath-Plus)

---

*安装包中的产品名：**Peel**（`appId`：`com.peel.desktop`）。*
