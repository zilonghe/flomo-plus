# Weiji（微记）极简 UI / UX 设计规范与画板映射

本项目采用 **极度极简双端统一设计语言（暖纸黑墨 / 炭纸米墨）+ Ryugi 文件化画板驱动** 管理所有 UI/UX 资产：
- **双空间心智架构**：整站与原生 App 仅设 **笔记** 与 **AI** 两个顶层空间（取消独立漫步空间与独立洞察工作区——漫步合入统一全文阅读页，洞察视角合入 AI 空态与统一时间线历史）。
- **iOS**：遵循 **Apple HIG** — 取消底部 Tab Bar（顶栏 `≡ ｜ 笔记 · AI ｜ ⤨`）、系统语义 Dynamic Type、≥44pt 真实触控热区、全矩阵对比度 AAA（≥7:1）。
- **Web**：0 常驻左侧栏，单张 640px 居中素纸流、Anthropic 风格双字族排版（正文/阅读/AI 回答采用自托管 `Newsreader` 可变衬线 + 系统宋体，UI 控件保持 `Inter + PingFang SC` 无衬线，严格守住 `font-src 'self'` 零外链）、全角色 WCAG AA/AAA（≥4.5:1，正文与强调色 ≥7:1）、移动端（≤768px / 375px）≥48×48px 真实触控热区。

---

## 1. Ryugi 画板文件结构与操作命令

当前权威极简画板由 Git 跟踪在 `.ryugi/artifacts/artboard/weiji-minimal/`（历史 4-Tab 参考画板存档于 `weiji-ui-flows/`）：

| 路径 | 职责 |
|---|---|
| `.ryugi/modules.json` | 业务模块词表 |
| `.ryugi/artifacts/artboard/weiji-minimal/canvas.json` | 4 页 22 画板极简全量交互与状态连线（`ios-notes` / `ios-ai` / `web-minimal` / `tokens-states`） |
| `.ryugi/artifacts/artboard/weiji-minimal/pages/tokens.css` | 平台中立语义 Token 单一事实源（覆盖 iOS / Web / 后续 Android） |
| `.ryugi/artifacts/artboard/weiji-minimal/pages/minimal-{ios,web}.css` | iOS 与 Web 极简原型样式 |
| `.ryugi/artifacts/artboard/weiji-minimal/pages/{ios,web,tokens}/*.html` | 各页面原型（含浅/深色、375px、AXL 超大字号、折叠热力图、生成中确认与冲突态） |

### 常用命令
```bash
# 启动并打开本地实时画板
ryugi start --background --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-minimal --mockup

# 读取用户在画板上留下的圈选与评论
ryugi comment list --sections all --detail --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-minimal

# 校验画板（检查布局、跨板连线、图标、裁剪与浏览器实测状态）
ryugi check --detail --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-minimal
```

---

## 2. 平台中立语义 Token（纸墨系统）

| 语义角色 | 浅色（暖纸黑墨） | 深色（炭纸米墨） | 用途限制 |
|---|---|---|---|
| `bg` / `Theme.canvas` | `#FAF8F4` | `#151514` | 全局单一纸面底色 |
| `surface` / `Theme.paper` | `#F2EFE8` | `#1F1E1C` | 仅输入框、抽屉、用户消息 |
| `fill` / `Theme.subtle` | `#EAE6DC` | `#272623` | 悬浮与轻按底 |
| `text` / `Theme.ink` | `#1C1B19` | `#E8E5DE` | 主墨（~15:1） |
| `text-secondary` / `Theme.ink2` & `ink3` | `#4E4B45` | `#B0ACA3` | 次墨（≥7:1 AAA；第三层级靠 13px + 0.04em 字距区分） |
| `inverse-bg` / `inverse-text` | `#1C1B19` / `#FAF8F4` | `#E8E5DE` / `#151514` | 主按钮、FAB、撤销条、停止键 |
| `accent` / `Theme.active` | `#1D4D3A` | `#9AC4AE` | **极窄强调**：仅行内可点 `#标签`、引文 `[1]` 与可用发送键（≥7:1） |
| `danger` / `Theme.danger` | `#9A2620` | `#F59C95` | 冲突、报错、删除确认（≥7:1） |
| `separator` / `Theme.hairline` | `rgba(28,27,25,0.10)` | `rgba(232,229,222,0.12)` | 仅结构边界，**笔记之间绝不画线** |
| `quote-bar` / `Theme.quoteBar` | `rgba(28,27,25,0.24)` | `rgba(232,229,222,0.28)` | 读书摘录左侧 `1.5px` 细竖线 |
| `heat-0..4` / `Theme.heat(level:)` | Ink alpha `0.06..0.88` | Ink alpha `0.08..0.90` | 筛选面板内可折叠无框水墨热力图 |

---

## 3. 画板页面与业务源码映射

| 画板页面 ID | 页面名称 | 对应源码路径 |
|---|---|---|
| `ios-notes` | iOS · 笔记与统一阅读 | `ios/Weiji/Views/RootTabView.swift`, `Notes/{NotesTabView,SidebarSheetView,QuickComposerSheet,NoteReaderView}.swift`, `State/WalkStore.swift` |
| `ios-ai` | iOS · AI 空间与三行设置 | `ios/Weiji/Views/AI/{AIChatView,SessionsSheetView,PinPickerSheet}.swift`, `Insights/{CustomLensSheet,ProfileWorkspaceView}.swift`, `Settings/{LoginView,ConnectionSettingsView}.swift` |
| `web-minimal` | Web · 无侧栏素纸流 | `public/index.html`, `public/styles.css`, `public/app.js`, `public/joplin.js`, `public/weread.js` |
| `tokens-states` | 纸墨系统 · 明暗与 AXL | `ios/Weiji/Views/Theme.swift`, `public/styles.css` |

> Android 跟进项：本轮不动 `android/`，后续按第 2 节平台中立 Token 与双空间导航同步升级 Android 客户端。

---

## 4. UI 质量硬红线（改代码与画板均不可违背）

1. **禁止根级 `.foregroundStyle` 毒化按钮对比度**：`RootTabView` 不施加全局 `.foregroundStyle(Theme.ink)`；实底按钮采用纸墨反色（`Theme.inverseBg` / `Theme.inverseText`）或深墨绿配白字，全态 ≥7:1。
2. **禁止大面积面板使用透明玻璃与装饰噪音**：侧栏抽屉、弹窗等大容器一律实底表面（`Theme.canvas`）并严格 `.clipped()`；禁止 `.glassEffect`、禁止任何渐变、`sparkles` 图标、非模态卡片阴影、笔记间横线与 5 色换肤/AI 厂商色。
3. **统一阅读与防误触契约**：全文阅读页合并随机读与底部 3 条静默相关笔记（零相似度数字、零 SVG 连线）；顶栏直出 `编辑` 按钮（点正文/选字/点 `#标签` 绝不误触编辑）；Zoom 转场使用复合 `NoteZoomID(source, id)`。
4. **真实触控热区与键盘焦点（严禁假热区）**：
   - iOS 所有可点控件真实命中区域 ≥44×44pt；日期筛选使用 ≥44pt 按钮弹出 `.datePickerStyle(.graphical)` Sheet；筛选抽屉统计行默认收起（1 行 `≥44pt`），点击就地展开无框 12 周单色水墨热力图。
   - Web ≤768px 移动端顶栏、输入发送键、筛选抽屉、设置与对话框控件真实命中盒均 ≥48px 且无页面横向溢出；抽屉/弹窗必须支持键盘 Escape 与可聚焦关闭按钮并在关闭后归还焦点。
5. **动态字号与无障碍对比度**：
   - iOS 禁止硬编码固定数字字号，全部使用语义 Dynamic Type 或 `@ScaledMetric`；AXL 超大字号下保存、停止、关闭、编辑按钮不可被遮挡；`Theme.adaptive` 常规与高对比度双模式核心组合全过 ≥7:1 AAA。
   - Web 浅/深色含 `/login` `.auth-shell` 与 placeholder 均 ≥4.5:1 AA（正文与强调色 ≥7:1）；中文 IME 组合态回车绝不误发笔记或消息。
6. **静默常态与状态安全底线**：正常同步 0 像素不提示；离线/待上传/409 冲突必须在对应笔记旁清晰说明并给明确动作；删除提供 `撤销` 恢复；AI 会话草稿隔离、在途流切换弹窗保护、纯查看引文返回原滚动位不可破坏。
7. **Web AI 步骤卡防溢出**：检索步骤默认折叠为单行 `参考了 N 条笔记 ›`，展开态严格保持 `.ai-steps-card .ai-step-list { display: block; min-width: 0 }` 与标题单行省略，避免桌面/375px 下横向撑爆。
