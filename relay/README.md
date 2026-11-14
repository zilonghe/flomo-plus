# 微记本地 Codex 中继

用一台可常开的 Mac 或 Linux 主机运行中继。在主机上登录自己的 ChatGPT 账号，微记通过中继调用 Codex，使用该账号的 Codex 额度。网页站点仍负责笔记同步。主机离线时仍可写笔记，Codex 回复要等中继恢复。

## 启动

需要 Node.js 22 或更新版本，以及支持 `codex app-server` 的 [Codex CLI](https://learn.chatgpt.com/docs/cli)。下载 [server.mjs](/relay/server.mjs)，放在主机上。为中继使用一个独立的操作系统账户和空的 Codex 配置目录，避免主机上的项目、插件和其他凭证进入工作环境。

```sh
umask 077
export WEIJI_CODEX_HOME="$HOME/.weiji-codex"
mkdir -p "$WEIJI_CODEX_HOME"
CODEX_HOME="$WEIJI_CODEX_HOME" codex login
CODEX_HOME="$WEIJI_CODEX_HOME" codex login status
```

选择用 ChatGPT 登录。无桌面的主机可在账号设置启用设备码后，把命令换成 `codex login --device-auth`。参考[官方登录文档](https://learn.chatgpt.com/docs/auth)。

用密码管理器生成随机中继密钥，建议 64 位十六进制。将同一个值配置到主机进程的 `WEIJI_RELAY_TOKEN` 与微记部署的 `CODEX_RELAY_TOKEN`。通过主机服务管理器的环境变量或权限受限的环境文件传入。`WEIJI_CODEX_HOME` 与密钥都设置好后，运行 `node server.mjs`。

中继监听 `127.0.0.1:8787`。可通过 `WEIJI_RELAY_PORT` 改端口，通过 `WEIJI_CODEX_BIN` 指定 Codex 的绝对路径。`WEIJI_CODEX_MODEL` 可选，可填当前账号能用的 Codex 模型。

## 连到微记

在主机上配置一个 HTTPS 反向代理或出站隧道，让它将 `/journal/reply` 转发到本机 `127.0.0.1:8787`。Cloudflare Worker 需要能通过 HTTPS 到达该地址。在 [ChatGPT Sites](https://chatgpt.com/sites) 打开「微记 → 设置 → 环境变量」，将完整 HTTPS 地址（包括 `/journal/reply`）配置为 `CODEX_RELAY_URL`，将相同中继密钥作为密钥值配置为 `CODEX_RELAY_TOKEN`。隧道只需暴露这个接口。Codex App Server 通过进程的标准输入输出通信，网页及站点都不接收 Codex 登录凭证。

在微记里选择 Codex 中继，再打开一条笔记提问。中继在主机上检查 Codex 当前登录类型，并在临时目录中启动仅用于文本回复的会话。请求只携带当前笔记和最近对话，主机一次处理一条，最多等待 90 秒。中继不记录笔记正文、对话、密钥或 Codex 的输出。主机启动后仍需用你自己的账号完成一次真实回复以验证网络、账号和模型可用。
