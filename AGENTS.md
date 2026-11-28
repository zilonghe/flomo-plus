# Weiji（微记）项目工程与 UI 规范入口

## 1. 仓库与环境基线
- **Web**：源码 `public/` + `src/`，构建 `npm run build`（输出 `dist/`）。
- **iOS**：通过 `ios/project.yml`（XcodeGen）管理工程。**严禁在仓内遗留 `ios/Weiji.xcodeproj`**；所有测试、Simulator 验证和真机构建均拷贝 `ios/` 到 `/tmp` 隔离目录执行，用完清理。
- **核心验证命令**：
  - Web & Chromium：`npm run build && node --experimental-sqlite --test test/s3-backup-obsidian.test.mjs test/ai-ux-perf.test.mjs test/joplin-import.test.mjs test/writing-style.test.mjs`（要求 `skipped 0`）。
  - iOS 单测：在 `/tmp` 副本执行 `xcodegen generate && xcodebuild -project Weiji.xcodeproj -scheme Weiji -destination 'platform=iOS Simulator,name=iPhone 17' GENERATE_INFOPLIST_FILE=YES CODE_SIGNING_ALLOWED=NO test -only-testing:WeijiTests`。
- **上线部署**：东京 VM `ubuntu@35.213.39.188:/opt/weiji`（`git pull --ff-only origin main && npm run build && sudo systemctl restart weiji.service`）；真机安装至 `00008150-001869E81483401C`（`-configuration Release -allowProvisioningUpdates build` 后 `xcrun devicectl device install app`）。

## 2. UI / UX 修改强制 SOP（触碰任何界面必守）
凡修改 `ios/Weiji/Views/**`、`public/index.html`、`public/styles.css`，或新增/调整页面、弹窗、跳转路径与配色字号，**必须按以下顺序执行**：

1. **先读设计规范**：阅读根目录 [`DESIGN.md`](./DESIGN.md)，确认 HIG / M3 规范与 7 条 UI 硬红线。
2. **先对齐 Ryugi 画板**：
   - 画板路径：`.ryugi/artifacts/artboard/weiji-minimal/`（历史 4-Tab 参考存档于 `weiji-ui-flows/`；模块词表 `.ryugi/modules.json`）。
   - 若用户已在画板留评，先读取未处理评论与选区；若涉及结构、跳转、状态或 Token 变更，先更新对应 `pages/**/*.html`、`pages/tokens.css` 或 `canvas.json`。
   - 改动画板后必须跑通 `ryugi check`（0 跨板连线、0 裁剪、0 未知图标）并经浏览器加载清理 pending。
3. **再同步改代码**：
   - 保持 `pages/tokens.css` 与 `ios/Weiji/Views/Theme.swift`、`public/styles.css` 语义和色值一致；严禁只改代码不更新画板，或只改画板漏改代码。
4. **验证收口**：
   - Web 改动必过 Chromium 双主题对比度与 375px 48×48px 热区测试；
   - iOS 改动必过 `TagAndCitationTests`（含高对比度 52 对 ≥7:1）及 Simulator 浅色/深色/AXL 超大字号实测。
