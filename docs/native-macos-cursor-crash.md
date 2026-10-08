# 光标崩溃诊断（2026-10-08）

## 用户报告：尚未定位根因

发行版基点 `f7084ad`，Apple Silicon / macOS 27.0 (26A428)，启动约 45 秒后主线程 EXC_BAD_ACCESS。堆栈为 `NSCursor.set → SLSRegisterCursorWithImages2 → CGContextDelegateFinalize → ripc_Finalize → x_list_remove`。该报告只定位到系统光标注册时发生非法内存访问，不能证明 AppKit 本身有问题，也不能证明下述空行缺陷是它的根因。

本机隔离诊断尝试：

- 发行版编辑器创建、绘制、释放及自定义/系统光标切换，每轮 2,000 次，多轮未复现原始堆栈。
- 增加行号区已注册光标、MallocScribble/MallocGuardEdges，仍未复现。
- ASan 下增加并发空闲内存回收，2,000 次未报错（先应用下述空行补丁）。
- 隔离数据的完整 ASan 应用测试左右面板隐藏/重建，鼠标点击三个编辑器正文及行号区，未复现原始崩溃。

待补充闪退前的具体操作、是否稳定复现。尚未为了猜测根因而修改光标样式、窗口布局或内存回收策略。

## 独立确认并修复：空行布局越界读取

ASan 原生绘制原型首次运行即退出 134：

```
ERROR: AddressSanitizer: heap-buffer-overflow
READ of size 1
LineLayout::CalculatePositions — PositionCache.cxx:433
1 byte before 1-byte region
```

Scintilla 5.6.7 在空行时 `numCharsBeforeEOL == 0`，仍读取 `chars[numCharsBeforeEOL - 1]` 判断末尾斜体。补丁先判断是否有字符，再读取末字符。它是已证实的越界读取；没有证据说明该读取造成用户报告中的 CoreGraphics 内存损坏。

补丁保存在 `apps/native-macos/patches/scintilla-empty-line-layout.patch`，由依赖准备脚本在下载后应用；重复运行不重复应用，源文件不匹配时失败。

原生编辑器此前约定使用原型/交互验证。本次保留 ASan 绘制原型，可在登录的 macOS 图形会话中运行：

```sh
python3 apps/native-macos/scripts/diagnose-editor.py
```

它创建隔离 app bundle，绘制空文档、空行、末尾换行和普通 JSON，共 500 次创建/绘制/释放，并注册光标。ASan 错误或缺少完成标记即失败。它不读取用户历史，也不作为原始光标闪退已经修复的证据。

最终验证：诊断输出 `EDITOR_LIFECYCLE_PASS=500`，进程退出码为 0；20 个核心测试通过。补丁在还原到原版源码后可应用，重复准备不重复修改文件；Release 构建与应用签名校验通过。复审修正了诊断成功标记提前输出的问题，最终 Standards / Spec 均无未解决代码发现。原始闪退仍待触发步骤。
