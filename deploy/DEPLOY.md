# 微记公网部署

## VPS 准备

准备 Linux VPS、域名、Caddy、SQLite CLI 和 Node.js 24 LTS（最低 Node 22，须支持 `node:sqlite` 与 FTS5）。将域名的 A/AAAA 记录指向 VPS，仅对外开放 80、443 和受限 SSH。微记和可选的 CLIProxyAPI 均绑定回环。以下示例假定 Node 在 `/usr/bin/node`，安装路径不同时修改 unit。

以发布的提交安装到 `/opt/weiji`，在该目录运行 `npm ci --omit=dev`。现有构建脚本在服务启动时删除并重建 `dist/`，因此示例把这一份发布副本交给专用 `weiji` 用户。凭据始终放在 `/etc/weiji`。

```sh
sudo useradd --system --home-dir /var/lib/weiji --shell /usr/sbin/nologin weiji
sudo install -d -m 0750 -o root -g root /etc/weiji
sudo install -d -m 0700 -o weiji -g weiji /var/lib/weiji
sudo chown -R weiji:weiji /opt/weiji
sudoedit /etc/weiji/server.env /etc/weiji/backup.env
sudo chmod 0600 /etc/weiji/server.env /etc/weiji/backup.env
sudo install -m 0644 deploy/weiji.service.example /etc/systemd/system/weiji.service
sudo install -m 0644 deploy/weiji-backup.service.example /etc/systemd/system/weiji-backup.service
sudo install -m 0644 deploy/weiji-backup.timer.example /etc/systemd/system/weiji-backup.timer
sudo systemctl daemon-reload
```

按 [env.example](env.example) 分别填写两个 environment 文件，备份文件也需同一个 `SQLITE_PATH`。不要启动仍使用占位凭据的服务。配置 `PUBLIC_ORIGIN=https://你的域名`，不要添加尾斜杠。按需配置一家或两家 OAuth，未使用的提供商留空：

| 提供商 | 注册的回调 URL |
| --- | --- |
| GitHub OAuth App | `https://你的域名/auth/github/callback` |
| Google Web application | `https://你的域名/auth/google/callback` |

Google OAuth 对外发布前核对 consent screen 的发布状态。OAuth 提供商只登记 HTTPS 回调；`weiji://auth/callback` 是微记服务返回给 iOS 的回调。反代用 [Caddyfile.example](Caddyfile.example)，替换域名，运行 `caddy validate --config /etc/caddy/Caddyfile` 后再加载。保持 `flush_interval -1`；Caddy 覆写客户端 IP。不要记录 OAuth 路径的完整查询参数，也不要记录 Cookie 或 Authorization。

## AI 网关（可选）

可以直接配置兼容 OpenAI 的上游 `OPENAI_BASE_URL` 和 `OPENAI_API_KEY`。若使用同机 CLIProxyAPI，安装其 Linux 二进制至 `/usr/local/bin/cli-proxy-api`，创建专用用户及目录：

```sh
sudo useradd --system --create-home --home-dir /var/lib/weiji-cpa --shell /usr/sbin/nologin weiji-cpa
sudo install -m 0644 deploy/cpa.service.example /etc/systemd/system/weiji-cpa.service
sudoedit /etc/weiji/cpa.yaml
sudo chown weiji-cpa:weiji-cpa /etc/weiji/cpa.yaml
sudo chmod 0600 /etc/weiji/cpa.yaml
sudo setfacl -m u:weiji-cpa:--x /etc/weiji
```

按所安装版本的 CLIProxyAPI 文档，以 `weiji-cpa` 用户完成上游登录，将账号凭据限制在 `/var/lib/weiji-cpa`。最小配置示意：

```yaml
host: "127.0.0.1"
port: 8317
auth-dir: "/var/lib/weiji-cpa/.cli-proxy-api"
api-keys:
  - "replace-me"
```

`api-keys` 中实际生成的值与微记 `OPENAI_API_KEY` 一致，`OPENAI_BASE_URL=http://127.0.0.1:8317/v1`。用 `sudo systemctl daemon-reload` 和 `sudo systemctl enable --now weiji-cpa.service` 启动。用同一 API key 在本机验证 `/v1/models` 和一次生成，选择实际支持的 `OPENAI_MODEL`。

## 从 116 切流

1. 在 116 只读核对旧库分区。记录要迁移的账号和行数，核对其他六张表的分区与计数。先确认 GitHub 的数字用户 ID 或 Google 的不可变 `sub` 属于预期管理员，不能用邮箱或登录名替代。
   ```sh
   sqlite3 -readonly "$OLD_DB" 'SELECT DISTINCT account, COUNT(*) FROM journal_notes GROUP BY account;'
   ```
2. 约定停写窗口，停止旧服务及其他写库进程，保留旧库。用 `VACUUM INTO` 生成一致快照，校验后用 SSH 安全传输至 VPS 的暂存目录，不要复制运行中的 WAL 文件。
   ```sh
   umask 077
   sqlite3 -readonly "$OLD_DB" "VACUUM INTO '/secure/staging/weiji-cutover.db';"
   sqlite3 -readonly /secure/staging/weiji-cutover.db 'PRAGMA integrity_check;'
   ```
3. VPS 上确认新服务还没有接流量，保存原始快照，再以 `0600`、属主 `weiji` 把快照安装到配置的 `SQLITE_PATH`（如目标文件已存在，先核对并另存）。管理员 CLI 会应用迁移。在 `/opt/weiji` 运行，使用实际旧账号和返回的 `userId`：
   ```sh
   sudo -u weiji env SQLITE_PATH=/var/lib/weiji/weiji.db /usr/bin/node --experimental-sqlite scripts/admin.mjs \
     prebind-admin --provider github --subject "$GITHUB_USER_ID" --name "$OWNER_NAME"
   sudo -u weiji env SQLITE_PATH=/var/lib/weiji/weiji.db /usr/bin/node --experimental-sqlite scripts/admin.mjs \
     migrate-account --from "$OLD_ACCOUNT" --to "$NEW_USER_ID"
   ```
   目标必须在 7 张业务表全部为空，命令会在同一事务里拒绝覆盖。多个旧账号对应不同目标身份，逐一迁移；保留原库中未迁账号的盘点结果。
4. 在新库只读查账：`journal_notes`、`note_embeddings`、`ai_sessions`、`ai_profile`、`note_fts`、`ai_insight_lenses`、`ai_insight_reports`。每张表的目标账号行数应与旧账号一致，旧账号应为 0；抽查笔记、对话及 FTS 搜索命中。
5. 通过 `sudo systemctl enable --now weiji.service` 启动新服务，检查 `journalctl -u weiji.service`。访问 HTTPS 域名，确认未登录 API 返回 JSON 401；用预绑定管理员验证登录、同步、AI 流式首帧、设备管理和邀请码。以邀请码测试 Web/iOS 新用户准入，并确认两账号数据隔离。核对通过后发放新地址，再开启下面的备份定时器。
6. 在首笔公网写入前回滚可停新服、切回旧地址并启动旧服。若公网已有写入，先停止新服写入、保存并校验新库快照，核对增量及账号映射后再决定回滚；不要让两边同时写入或用旧快照覆盖新数据。

## 邀请码与备份

运维命令以服务用户运行并明确指定 `SQLITE_PATH`。例如 `node --experimental-sqlite scripts/admin.mjs invite create --max-uses 1 --days 7 --note "测试"`；明文邀请码只在创建时显示。用 `invite list` 查看哈希和尾号，用 `invite revoke <codeOrHash>` 作废。账号停用用 `user disable <userId>`，会吊销该账号的活跃会话。

给备份凭据分配目标 bucket 的 List、Put、Delete 权限，使用微记独立前缀（结尾是 `/`）。先运行 `sudo systemctl start weiji-backup.service`，查看 `journalctl -u weiji-backup.service` 及 R2 对象，再启用 `sudo systemctl enable --now weiji-backup.timer`。默认每日 UTC 03:00，按配置仅清理本前缀的过期 `.db.gz`。备份含私有笔记与账号元数据，限制存储访问。

定期下载一份快照到受限目录并用 `node --experimental-sqlite scripts/backup-r2.mjs --verify snapshot.db.gz` 验证。恢复前停止服务，先保存当前库及 WAL，再把解压的新库安装到单独路径做完整性和数据核对；切换 `SQLITE_PATH` 后重启。恢复旧快照可能恢复当时还活跃而后来被吊销的会话，切换前在恢复库吊销所有旧会话并删除未完成的 OAuth 状态，要求用户重新登录。
