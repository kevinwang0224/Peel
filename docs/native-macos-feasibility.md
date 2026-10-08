# Peel 原生 macOS 重构可行性评估

评估日期：2026-10-08。基于当前仓库静态分析、原生组件官方资料和用户三轮需求确认。初始评估时尚未制作原型或实测性能；本文中的目标数字是验收标准，不是收益承诺。现已进入实施，当前构建与验证说明见 `apps/native-macos/README.md`。

## 结论

可行，建议继续做原型验证。Peel 是功能集中的本地 JSON 工作台，没有登录、云同步、终端、复杂插件或浏览器嵌入等迁移负担。窗口、菜单、文件和剪贴板容易替换；最大成本在 Monaco 的编辑体验替代，其次是脚本可中止执行和 JSON 行为兼容。

建议采用 Swift 原生界面、AppKit 原生编辑器、SQLite 存储、独立 JavaScriptCore 辅助进程。首版曾采用 AppKit 工作台；后续按用户要求迁移为 SwiftUI 界面，以小范围 AppKit 桥接保留编辑器和窗口生命周期，并通过 Observation、正文版本更新及后台空闲回收控制开销。移除 Electron、Chromium、Node 桌面运行时及 WebView。JavaScript 引擎只负责提取，不承载界面。首版无需引入 Rust 或自研通用跨平台架构。

这是桌面实现重写，不是简单换壳。现有数据契约、行为测试、历史数据和交互设计能继承；React、CSS、Electron 实现无法直接变为原生代码。

## 已确认范围

| 项目 | 用户选择 |
| --- | --- |
| 平台 | macOS 14+，首版仅 Apple Silicon，本机自用 |
| 原生边界 | 界面与编辑器都原生，无 WebView；允许 JS 引擎 |
| 主要负载 | 日常单份 JSON ≤1 MB；10 MB 压测；1000 条历史 |
| 编辑器首版 | 高亮、行号、JSON 校验及定位、格式化/压缩、查找替换、撤销重做、折叠 |
| 可后置能力 | JS 智能补全、多光标；不承诺 Monaco 全部语言服务等价 |
| 提取 | 保留 JavaScript data 表达式与 JSONPath；不承诺 fetch 等浏览器 API 及依赖这些 API 的异步脚本 |
| 自动提取 | ≤1 MB 时停输 400 ms 后执行；更大文档手动执行；每窗口一个任务，新输入取消旧任务；约1.2秒超时 |
| 数据 | 迁移历史、固定状态、标题、表达式和设置，保留历史正文搜索；保留旧文件以便回退 |
| 常驻 | 保留菜单栏和全局快捷键；主窗口关闭、保存完成后释放其编辑器和文档缓存，释放空闲脚本进程；临时窗只加载自身内容 |
| 初始性能门槛 | 发行版冷启动可输入 ≤1秒；空闲应用总内存 ≤100 MB；1 MB 文档编辑 P95 响应 ≤50 ms |

## 组件替换表

以下难度为相对工程复杂度，不是已验证的实现耗时。

| 现有组件 | 原生候选/处理方式 | 难度与关键约束 |
| --- | --- | --- |
| Electron 主窗口、临时窗口 | NSWindow / NSWindowController 保留生命周期，NSHostingController 承载 SwiftUI 界面 | 低至中；保留临时窗口保存/丢弃和焦点行为 |
| React hooks、Tailwind、Radix/shadcn | SwiftUI 控件与 Observation 原生模型状态 | 中；需重写，保留工作台布局和流程，无需逐像素复制 CSS |
| Framer Motion、Sonner、Lucide | 原生动画、轻量反馈、SF Symbols 或既有资源 | 低；避免后台持续动画 |
| JSON 原文 Monaco | 优先验证 Scintilla + Lexilla 的 Cocoa 版本，以 STTextView 作对比候选 | 中至高；有现成高亮和折叠基础，仍需 Swift 桥接、错误范围、输入法、长行等验收 |
| JS/JSONPath 表达式 Monaco | 同一原生编辑器封装，按语言启用功能 | 中；JS 高亮与执行保留，完整 JS 语义诊断/补全不作为首版承诺 |
| 结果 Monaco | 同一组件的只读模式；隐藏面板不创建编辑器 | 中；按需创建，避免无条件维持三个重量实例 |
| jsonc-parser / JSON 帮助函数 | 原生严格 JSON 处理层，按行为样例移植 | 中；Foundation 不能自动提供所有现有错误位置、去转义和格式保真行为 |
| JavaScript new Function + Worker | 独立辅助进程内 JavaScriptCore，显式请求/响应协议 | 中至高；保留 data、结果类型、超时、取消，验证跨进程峰值 |
| jsonpath-plus | 优先将现有库打包为 JavaScriptCore 可加载的 JS | 中；核对无 Node/DOM 依赖的打包、filter 求值、方言和结果形态，不直接假定 npm 包可运行 |
| 全量 JSON 历史文件 | SQLite 按条更新，列表元数据查询，正文按需加载 | 中；迁移与正文搜索语义必须保持 |
| preload / IPC 门面 | 原生应用服务调用；仅脚本辅助进程保留 IPC | 低；无需照搬 renderer/main 分层 |
| 文件打开/导出 | NSOpenPanel、NSSavePanel、原生文件 API | 低；仍需中文路径、取消及错误处理 |
| 剪贴板、菜单栏、菜单 | NSPasteboard、NSStatusItem、NSMenu、responder chain | 低至中；验证无选区复制、粘贴转换和焦点路由 |
| 全局快捷键 | macOS 热键注册封装 | 中；保留冲突检测，转换现有 Electron accelerator 设置 |
| electron-builder、Vite 桌面构建 | Xcode / Swift Package Manager | 中；首版本机运行，公开分发的签名、公证、升级另行纳入范围 |
| 浏览器扩展工作区 | 保持独立，当前仅占位 | 无现成功能迁移成本；未来扩展不能直接复用 Swift UI/核心 |

### 原生编辑器不是现成的 Monaco 等价品

- **补充调研后的优先候选：[Scintilla](https://www.scintilla.org/ScintillaDoc.html) + Lexilla 的 Cocoa 版本。** Scintilla 是长期维护的 C++ 原生编辑组件，提供折叠、标记、查找替换、撤销等基础能力；[Lexilla 的 JSON lexer](https://github.com/ScintillaOrg/lexilla/blob/master/lexers/LexJSON.cxx) 已实现 JSON 高亮和折叠。Cocoa 版本不依赖 Electron、WebView 或 Qt，可以用 Objective-C/Objective-C++ 桥接后嵌入 SwiftUI。它是通用编辑组件，严格 JSON 校验、格式化、错误消息和查找面板仍需应用集成。Swift 桥接、中文输入、无障碍、Retina 和长行性能须实际验证。
- Scintilla 的[发布记录](https://www.scintilla.org/ScintillaHistory.html)显示 2026-09-28 发布5.6.7，近期仍有内存优化和 Cocoa 修复。采用[Scintilla 许可](https://www.scintilla.org/License.txt)。这些是成熟度与维护证据，不代表已经测得 Peel 的性能指标。
- [STTextView](https://github.com/krzyzanowskim/STTextView) 当前文档要求 macOS 14+，提供行号、查找替换、撤销、插件化高亮等。它是对比候选，不是已完成选型；不能据功能介绍推定项目需要的折叠、诊断和粘贴行为全部现成可用。当前官方说明为 GPLv3，也提供商业许可。
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) 面向代码行布局，明确说明不追求系统文本视图全部行为；中文输入、选择和长行必须实际验证。
- [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) 提供更丰富的编辑功能，但官方仍标注未准备好用于生产，不建议未经验证直接作为唯一基础。
- [AppKit TextKit](https://developer.apple.com/documentation/appkit/textkit) 可作为系统文本能力基础。最终采用哪条路线由原型决定，不能凭“原生”二字认定一定满足性能门槛。

## 必须与技术栈一起改的数据流

1. **编辑渲染与 JSON 计算解耦。** `apps/desktop/src/renderer/src/app/App.tsx:239` 每次渲染调用 `summarizeJson`；`packages/shared/src/json.ts:101` 内含验证、再次解析、递归统计和全文 UTF-8 编码。原生版应按文档版本做后台计算，丢弃过期结果，避免布局/菜单变化触发全文处理。
2. **历史只按记录保存。** `apps/desktop/src/main/storage.ts:164` 每次保存全量规范化、写整个 JSON 文件并克隆快照。改为 SQLite 单记录事务，向界面发送变更记录 ID，不返回完整历史正文。
3. **窗口不加载全部历史正文。** 当前 `App.tsx:376` 的 bootstrap 发生在临时窗口分支判断之前。原生列表只取元数据；临时窗口只读取设置和自身文档。
4. **提取请求有版本、取消和超时。** 当前 `extraction-client.ts:3` 超时为1200 ms，使用 Worker.terminate；`extraction.ts:43` 又对数据 structuredClone。原生版优先传输入文本，由辅助进程解析，避免主界面建立对象树再传完整对象；仍需测量输入/输出传输的内存峰值。
5. **限制任务堆叠。** 应用级调度限制并发辅助任务；每个窗口只保留最新请求。取消或超时后，旧结果不得覆盖新文档。
6. **关闭窗口确实释放资源。** 保存完成后释放该窗口文本缓冲、撤销栈和解析缓存；没有任务后退出辅助进程。不能只隐藏窗口来满足低常驻目标。

SQLite 正文搜索应保留现有“不区分大小写的子串匹配”意图。FTS 分词搜索并非相同行为，不应直接替代；先在后台扫描数据库正文或使用经验证的查询，必要时再优化索引。历史总量和条数均需作为性能测试维度。

## JS 与 JSON 兼容性风险

[JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) 能在原生应用中执行 JS，不需要 WebView。但它不等同于浏览器 Worker：不能默认拥有 fetch、structuredClone、定时器或相同事件循环。

首版应把 jsonpath-plus 和必要帮助函数打成兼容包，显式桥接结果和异常；JSON 输入可以在辅助进程内直接解析为独立对象，再施加只读约束。Promise 支持需验证纯 JS 异步结果的结算与超时，浏览器 API 不在承诺范围。

**后台线程不等于可中止脚本。** 采用辅助进程是为了在死循环时能够终止并重建执行环境；不能把 Task.cancel 或 XPC 连接失效当作脚本已终止。原型需用真正死循环验证父进程的终止和回收路径，再决定具体 helper/XPC 组织方式。脚本进程只接收请求所需数据，不暴露任意本机文件/系统桥接。

JSONPath 必须核对现有 `wrap: true`、零结果、单结果展开、多结果数组及 filter 方言。JSON 处理还需核对根标量、null、超大整数、对象键顺序、重复键、转义、emoji 和 UTF-16 错误偏移。不要以“某个原生库也叫 JSONPath/JSON parser”推定等价。

已发现现有语义疑点：`packages/shared/src/json.ts:82` 把合法 JSON `null` 与空输入合并处理，格式化可能返回空字符串。迁移测试应区分明确产品行为和旧实现缺陷，不能机械复制全部输出。当前测试可作起点，但不足以证明完整兼容。

## 验证方法与推进顺序

### 阶段一：建立基线和两个小原型

- 同一台 Mac、发行版、相同输入测量现有 Electron 和原生候选；记录冷启动/再次启动，首次安装后的系统检查单独报告。
- 编辑器原型验证1 MB普通JSON、10 MB压测、单行压缩JSON、深嵌套、中文/emoji。验收高亮、折叠、查找替换、错误定位、粘贴、撤销、输入法及触控板选择。
- 脚本原型验证现有 JS/JSONPath 样例、异常、死循环、连续修改取消、超时后恢复及内存回收。
- 性能目标未达标前，不把候选组件锁定为正式架构。无需先完成全部 UI 才发现编辑器不适合。

### 阶段二：完成原生纵向功能

实现一个文档的编辑、验证、格式化、提取和保存，再接入历史及设置。共享 TS 中的行为样例提取为语言无关 fixtures，分别验证原生实现和保留的 JS 引擎逻辑。只移植实际需要的能力，不为未来跨端预建抽象层。

### 阶段三：迁移和系统集成

事务导入旧 schema 与旧目录数据，保留旧文件，不覆盖旧 Electron 数据。迁移应可重复启动而不重复导入；校验记录数量、正文、ID、时间、固定状态、表达式及设置。接入菜单栏、全局快捷键、临时窗及关闭保存/丢弃流程。

### 阶段四：性能与回归验收

| 场景 | 方法/门槛 |
| --- | --- |
| 冷启动 | 从进程启动到当前文档可输入，≤1秒；分空库与1000条历史测试 |
| 主窗空闲 | 1 MB文档、操作停止并完成回收后，全部应用相关进程内存≤100 MB |
| 菜单栏常驻 | 关闭主窗、无临时窗，确认编辑器/缓存/helper释放；单独记录内存与唤起耗时 |
| 编辑响应 | 1 MB代表性文档，输入事件到显示更新 P95≤50 ms；JS/校验不能阻塞输入 |
| 10 MB压力 | 记录打开、滚动、查找、格式化、手动提取的耗时与峰值；不套用1 MB的全部响应门槛 |
| 历史规模 | 1000条×10 KB和1000条×1 MB两组固定样本，验证启动不随总正文线性驻留 |
| 多窗口 | 主窗+3个临时窗作为初始压力样例，关闭后验证内存回落；不是窗口数量产品上限 |
| 异常脚本 | 死循环被终止、取消后旧结果不落地、后续提取恢复正常、helper不累积 |

内存统一记录 macOS physical footprint，并同时报告进程分项、总和与操作峰值；不能只看主进程或把安装包体积当成运行内存。单一“1000条历史”不足以定义负载，因此上述每条正文大小是建议的测试夹具规格，不是额外产品限制。

现阶段没有基准数据，不能给出“减少多少百分比内存”或“快几倍”的可信结论。去掉浏览器运行时有降低固定开销的理由，但是否达到100 MB、1秒和50 ms仍由原型决定。

本机已核实具备 Apple M3 Max / 36 GiB 内存、macOS 27.0、Xcode 27.0 / Swift 6.4，SDK 支持 macOS 14.0 deployment target，可作为首轮原型基准环境。这只能验证本机表现；声明兼容 macOS 14仍需对应系统运行验证。

现有共享包有22个测试（JSON 11、提取5、历史6），本次只阅读未执行。缺少性能、Promise查询、死循环、复杂JSONPath、数字精度和Unicode偏移覆盖；不能把旧测试全部通过当成原生版验收完成。

## 工程成本判断

普通界面和系统壳：低至中；数据迁移与存储重设计：中；脚本行为兼容与可靠终止：中至高；编辑器体验补齐：高，也是主要排期不确定性。

优先投资编辑器和脚本验证。若编辑器候选无法稳定满足折叠、输入法、撤销及目标性能，应调整组件或重新讨论功能范围，再继续完整重写。当前信息不足以给出可靠的固定工期。

用户已确认实施。当前原生工作区位于 `apps/native-macos`，采用 SwiftUI、Scintilla Cocoa 的 AppKit 桥接、SQLite 和 JavaScriptCore helper；旧 Electron 工作区作为迁移对照保留。性能实测记录将在实施报告中列明测量口径与未覆盖项。
