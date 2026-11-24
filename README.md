# 微记网页版

在 Sites 上打开已发布的微记，用创建此站点的 ChatGPT 账号登录；自托管启动见下文。首页可以写日志、搜索和按标签筛选。每条笔记都可以打开独立的 AI 对话，也可以从读书页面导入微信读书。

笔记、读书元数据与 AI 对话保存在站点对应账户的数据库。每次编辑校验笔记的云端版本，以免覆盖其他设备较新的修改。删除会同步到同一账户的设备。

网页版 AI 可使用服务端配置的网关、Codex 中转或你输入的 OpenAI API Key。手动输入的密钥在当前页面内存中保留，刷新页面后需重新填写。仅在发送问题时用该密钥请求 AI，笔记与近期对话会随请求提交。iOS 的 API Key 单独保存在系统钥匙串。

## 通过自己的 Codex 主机对话

在自己的 Mac 或 Linux 主机运行 [Codex 中转](relay/README.md)，在 Codex 登录 ChatGPT 账号，再配置站点的 `CODEX_RELAY_URL` 和 `CODEX_RELAY_TOKEN`。网页版设置会显示「Codex · ChatGPT 订阅」，此模式发送当前正文和近期对话到该主机。已有 OpenAI API Key 模式也可继续选用。

## 从微信读书导入

在「导入微信读书」里可连接微信读书官方 API。登录 [微信读书 Skill 官方页面](https://weread.qq.com/r/weread-skills)，获取 API Key 后填入微记，读取有笔记的书籍列表。选书并预览划线和个人想法，确认后保存。官方接口仅提供书签数量。

密钥只在当前导入窗口使用，通过微记后端传给微信读书官方接口。密钥不会写入笔记、账号数据库或网页存储。复制粘贴和 TXT、Markdown 文件导入也仍可使用。

## 从 flomo 迁移

在 flomo 网页版的「设置 → 账号详情」底部导出，然后在微记左侧选择「导入 flomo」。支持 flomo 导出的 ZIP 或解压后的 HTML。文件在浏览器内解析，预览后确认，笔记正文、日期和行内标签会保存到当前账号，并同步到已连接的 iOS 微记。重复导入相同导出文件时会跳过已有笔记。

导出时间未附带时区时，默认按北京时间解释，可以手动调整。图片和录音等附件不会导入，包含正文的笔记仍可正常迁移。

## 自托管（单账户）

需要 Node.js 22.16+ 或 24+，使用内置 SQLite，无第三方运行时依赖：

```sh
npm run dev
```

默认打开 `http://127.0.0.1:5173`，所有访问共用一个本地账户，不经过 ChatGPT 登录。默认数据库为 `:memory:`，重启即清空；需要保留笔记时指定 `SQLITE_PATH`：

```sh
SQLITE_PATH=./data/notes.db npm run dev
```

父目录会自动创建，文件数据库启用 WAL，迁移只执行一次，使用相同路径重启会保留数据。备份或迁移数据库前先停止服务，或使用 SQLite 备份工具；不要在运行时仅复制 `.db` 而遗漏 WAL。数据库、备份和导出文件不应提交到仓库，建议生产数据存放在仓库外。

### 监听与鉴权

`PORT` 默认为 `5173`，`HOST` 默认为 `127.0.0.1`。`127.0.0.1`、`::1`、`localhost` 以外的监听地址必须同时设置非空 `PREVIEW_AUTH_TOKEN`，否则立即拒绝启动：

```sh
HOST=0.0.0.0 PREVIEW_AUTH_TOKEN='<随机生成的长口令>' SQLITE_PATH=./data/notes.db npm run dev
```

设置口令后，页面和 API 均需鉴权。浏览器弹出的 HTTP Basic Auth 用户名可任填，密码为该口令；API 也可使用 `Authorization: Bearer <访问口令>`，或 `weiji_auth` Cookie（值为 URL 编码后的口令）。未通过返回 `401`。即使只监听回环，也可设置口令限制本机访问。

鉴权不提供传输加密。跨网络访问必须配合 HTTPS 反向代理或安全隧道，不要把明文 HTTP 直接暴露到公网。此模式没有独立多用户隔离，获准访问者都能读写同一份笔记。

### 服务端 OpenAI 兼容网关

通过环境变量配置网关，无需在浏览器填写密钥：

```sh
SQLITE_PATH=./data/notes.db \
PREVIEW_AUTH_TOKEN='<访问口令>' \
OPENAI_BASE_URL='https://gateway.example/v1' \
OPENAI_API_KEY='<网关凭证>' \
OPENAI_MODEL='gpt-5.4' \
npm run dev
```

- `OPENAI_BASE_URL`：合法的 HTTP/HTTPS API 基址，不含用户名、密码、查询或片段；末尾斜杠自动去除，请求追加 `/chat/completions`。
- `OPENAI_API_KEY`：1–512 个可打印 ASCII 字符，不能含空格；仅由服务端使用，不返回浏览器或写入笔记。
- `OPENAI_MODEL`：默认 `gpt-5.4`，允许 1–100 个字母、数字或 `_.:-`。

配置有效时，网页沿用「Codex · ChatGPT 订阅」入口并默认选中；服务端网关优先于 `CODEX_RELAY_*`，未配置有效网关时回退到原 Codex 中转。手动 OpenAI Key 模式仍直接请求 OpenAI。网关需自行完成订阅登录或上游凭证配置，本项目不处理 ChatGPT OAuth。

示例均为占位符。实际密钥和访问口令应从部署环境安全注入，不要写入源码或提交到 Git；本地环境文件不会自动加载。

## 开发

`npm run build` 将网页文件嵌入 Worker 入口，输出位于 `dist/server/index.js`，构建产物不入库。`drizzle/` 存放兼容 D1/SQLite 的迁移；自托管通过 `_migrations` 记录已执行文件，兼容已有的笔记表。Sites 部署仍需要登录网关注入账户身份，独立 Node 自托管使用上述单账户访问门禁。

## iOS 微记

原生 SwiftUI 客户端要求 iOS 18 或更新版本。它直连同一个自托管服务，支持笔记同步、标签筛选、随机漫步、带笔记引用的流式 AI 对话、洞察和个人画像。

在装有 Xcode 与 XcodeGen 的 Mac 上，从仓库根目录生成工程并打开：

```sh
xcodegen generate --spec ios/project.yml --project ios
open ios/Weiji.xcodeproj
```

选择 `Weiji` scheme，在模拟器运行。首次打开时，在「连接设置」填写自托管服务的完整地址和 `PREVIEW_AUTH_TOKEN`，点「测试并连接」。模拟器与服务器在同一台 Mac 时可填 `http://127.0.0.1:5173`；跨网络使用 HTTPS 或受信任的 VPN。笔记缓存按服务器和账号隔离。服务凭据与可选的 OpenAI API Key 保存在系统钥匙串；服务配置了 Codex 或兼容网关时，App 默认使用它。

单元测试在 Xcode 中选择 Product → Test。生成的 Xcode 工程和构建产物无需提交。

真机安装前，用 USB 连接并解锁 iPhone，信任这台 Mac，打开「开发者模式」，并在 Xcode 的 Accounts 中登录有 Team `GU3H6N2XND` 的 Apple 账号。从仓库根目录运行：

```sh
xcodegen generate --spec ios/project.yml --project ios
xcodebuild -project ios/Weiji.xcodeproj -scheme Weiji -showdestinations
WEIJI_DEVICE_ID='<上一步显示的 iPhone id>'
xcodebuild -project ios/Weiji.xcodeproj -scheme Weiji -configuration Debug \
  -destination "platform=iOS,id=$WEIJI_DEVICE_ID" -derivedDataPath ios/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=GU3H6N2XND build
xcrun devicectl device install app --device "$WEIJI_DEVICE_ID" ios/DerivedData/Build/Products/Debug-iphoneos/Weiji.app
xcrun devicectl device process launch --device "$WEIJI_DEVICE_ID" com.zilonghe.weiji
```

首次启动如提示不受信任，在 iPhone「设置 → 通用 → VPN 与设备管理」信任开发者，再启动 App。在连接设置中填写 iPhone 能访问的服务地址与访问令牌。

### 公开自托管

公网环境使用 Caddy HTTPS、GitHub / Google OAuth 和邀请码准入，Web 与 iOS 共用账号。部署、迁移历史数据、管理员操作及 R2 备份见 [部署手册](deploy/DEPLOY.md)。本地开发仍可使用原有的 `PREVIEW_AUTH_TOKEN`。
