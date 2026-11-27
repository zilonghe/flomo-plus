# Weiji（微记）UI / UX 设计规范与画板映射

本项目采用 **双平台原生对齐 + Ryugi 文件化画板驱动** 管理所有 UI/UX 资产：
- **iOS**：遵循 **Apple HIG（iOS 26）** — 原生导航容器、系统语义字体（Dynamic Type）、≥44pt 真实触控热区、增强对比度 AAA（≥7:1）。
- **Web**：遵循 **Material Design 3** — 浅色暖纸 + 深色炭灰五级 tonal surface、全角色 WCAG AA（≥4.5:1）、移动端（≤768px / 375px）≥48×48px 真实触控热区。

---

## 1. Ryugi 画板文件结构与操作命令

所有页面原型、跳转流和 Token 单一事实源均由 Git 跟踪在 `.ryugi/` 下：

| 路径 | 职责 |
|---|---|
| `.ryugi/modules.json` | 6 个长期业务模块词表（`design-system` / `notes` / `walk` / `ai-chat` / `insights` / `auth-settings`） |
| `.ryugi/artifacts/artboard/weiji-ui-flows/canvas.json` | 6 页全量画板布局、条件分支与跳转连线（`edges`） |
| `.ryugi/artifacts/artboard/weiji-ui-flows/pages/tokens.css` | 双端共享 Token 源（与 `Theme.swift`、`public/styles.css` 色值一一对应） |
| `.ryugi/artifacts/artboard/weiji-ui-flows/pages/weiji-ios.css` | iOS 共享原型样式 |
| `.ryugi/artifacts/artboard/weiji-ui-flows/pages/weiji-web.css` | Web M3 共享原型样式 |
| `.ryugi/artifacts/artboard/weiji-ui-flows/pages/{ios,web,tokens}/*.html` | 各页面原型（支持 `props` 复用多态/明暗模式） |

### 常用命令
```bash
# 启动并打开本地实时画板
ryugi start --background --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-ui-flows --mockup

# 读取用户在画板上留下的圈选与评论
ryugi comment list --sections all --detail --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-ui-flows

# 校验画板（检查布局、跨板连线、图标、裁剪与浏览器实测状态）
ryugi check --detail --project-dir /Users/bytedance/flomo-plus --artifact artboard/weiji-ui-flows
```

> `.ryugi/.gitignore` 已配置跟踪 `modules.json` 与 `artifacts/artboard/` 源码，自动忽略 `.state/`、`config.json`、`comments.json`、`.artifact-id`。

---

## 2. 画板页面与业务源码映射

| 画板页面 ID | 页面名称 | 对应源码路径 |
|---|---|---|
| `ios-entry` | iOS · 入口与笔记流 | `ios/Weiji/Views/RootTabView.swift`, `Settings/{LoginView,ConnectionSettingsView}.swift`（统一设置页含外观/AI/连接/同步）, `Notes/{NotesTabView,SidebarSheetView,QuickComposerSheet,NoteReaderView}.swift` |
| `ios-walk` | iOS · 随机漫步流 | `ios/Weiji/Views/Walk/RandomWalkView.swift`, `Notes/NoteReaderView.swift` |
| `ios-ai` | iOS · AI 对话流 | `ios/Weiji/Views/AI/{AIChatView,SessionsSheetView,PinPickerSheet}.swift`, `Settings/ConnectionSettingsView.swift` |
| `ios-insights` | iOS · 洞察与画像流 | `ios/Weiji/Views/Insights/{InsightsTabView,InsightReportSheet,CustomLensSheet,ProfileWorkspaceView}.swift`（栈内 Push：画板 → 配方/历史 → 报告 → 引用笔记，支持后台生成） |
| `web-flows` | Web · M3 桌面与移动流 | `public/index.html`, `public/styles.css`, `public/app.js`, `public/joplin.js`, `public/weread.js`（4 平级主视图：笔记/漫步/AI/洞察[含画像]，底部单一「导入笔记」入口） |
| `tokens` | 设计规范 · Tokens | `ios/Weiji/Views/Theme.swift`, `public/styles.css` |

---

## 3. UI 质量硬红线（改代码与画板均不可违背）

1. **禁止根级 `.foregroundStyle` 毒化按钮对比度**：`RootTabView` 不施加全局 `.foregroundStyle(Theme.ink)`；非破坏性主 CTA 统一用 `.buttonStyle(.weijiPrimary)` / `.weijiPrimaryWide`（白字实底）。
2. **禁止大面积面板使用透明玻璃**：侧栏抽屉、卡片、弹窗等大容器一律使用实底表面（`Theme.canvas` / `Theme.paper`）并严格 `.clipped()`；禁止在 `ios/Weiji/Views/` 中对大面板加 `.glassEffect`。
3. **原生导航与转场契约**：iOS 主导航使用原生 `TabView`、`NavigationStack`、`.toolbar`、`.searchable`、`.pickerStyle(.segmented)`；Zoom 转场使用复合 `NoteZoomID(source, id)`，漫步页焦点卡与关联卡均须注册 `matchedTransitionSource`。
4. **真实触控热区（严禁假热区）**：
   - iOS 所有可点控件真实命中区域 ≥44×44pt；禁止用 UIKit `.datePickerStyle(.compact)`（实测 ~34pt 边缘失效），须用真实 ≥44pt 按钮弹出 `.datePickerStyle(.graphical)` Sheet；侧栏 84 天热力图仅作视觉概览，不放 84 个小按钮。
   - Web ≤768px 移动端搜索框、顶栏、导航、标签展开箭头、热力图方格（横向滚动）、洞察 4 控件真实命中盒均 ≥48px 且无页面横向溢出（桌面端保持 40px 等高）。
5. **动态字号与无障碍对比度**：
   - iOS 禁止硬编码固定数字字号，全部使用语义 Dynamic Type 或 `@ScaledMetric`；AXL 超大字号下侧栏日期行自动上下堆叠、洞察配方卡自动切单列且分类/时间范围允许换行。
   - iOS `Theme.adaptive` 须维护常规 + `highLight`/`highDark` 增强对比度（52 组核心组合 ≥7:1 AAA）；Web 浅/深色含 `/login` `.auth-shell` 与 placeholder 均 ≥4.5:1 AA。
6. **短 Sheet 高度克制**：少量表单/选项的 Sheet（如日期选择 Sheet、自定义视角）必须声明 `.presentationDetents([.medium, .large])`，禁止默认撑满整屏；统一设置页（外观/AI/连接/索引/同步）与洞察 Push 栈内页不滥用嵌套 Sheet。
7. **Web AI 步骤卡防溢出**：保持 `.ai-steps-card .ai-step-list { display: block; min-width: 0 }` 与标题单行省略，避免桌面/375px 下横向撑爆。
