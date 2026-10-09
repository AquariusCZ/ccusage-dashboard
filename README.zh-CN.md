# AI Usage

[![验证](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml/badge.svg)](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml)

*[English](README.md)*

AI Usage 是一款本地运行的 Windows 用量面板，汇总 Claude Code 和 OpenAI Codex 的本地记录。
它会显示 Claude 套餐的真实额度，对比两款工具，并按公开 API 价格估算成本。会话内容不会上传。

成本数据适合比较用量和观察趋势，不代表订阅费用或服务商账单。

<table>
  <tr>
    <td width="72%"><img src="docs/dashboard.png" alt="AI Usage 桌面端界面"></td>
    <td width="28%"><img src="docs/mobile.png" alt="AI Usage 移动端界面"></td>
  </tr>
</table>

## 可以看到什么

- Claude 真实的五小时、七天额度，账户提供时也会显示按模型额度。
- Codex 真实的套餐额度，按 Codex 当前登录的账号读取。
- Claude 与 Codex 的成本、占比、调用、会话、Token 和缓存使用情况。
- 近七天、近三十天和全部历史三个周期。
- 每日趋势、活跃日历、连续活跃天数和 Claude 按小时用量。
- 模型构成、项目排行、高用量会话和明细表格。
- 明暗主题、移动端布局、键盘导航和减少动态效果。

模型成本始终与顶部预估一致。无法归属的差额会列为**未归属成本**，不完整的 Token
总数会标成下限。当前 5 小时窗口按最新的公开价目计价。价目取不到时，ccusage 会退回内置价目：
窗口里的模型内置价目都不认识时，窗口成本显示“未定价”，而不是 $0.00；认识与不认识的模型混用时，
只显示能定价的那部分。ccusage 通过 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量访问价目，不走 Windows
系统代理。

Claude Code 命令行已登录时，Claude 额度实时读取。Claude 桌面版有自己的登录，只用桌面版的
用户没有命令行令牌；这时卡片显示官方客户端本来就记在本机的最新记录（Claude Code 上一次的用量
响应，或桌面版的套餐用量采样，包括 MSIX 打包版存放在应用包目录里的那份），并标明来源和时间。
在终端运行一次 `claude auth login` 即可恢复实时数据。

Codex 额度跟随 Codex 的登录方式。用 ChatGPT 账号登录时，AI Usage 向官方 Codex 命令行查询该账号
的套餐额度（`codex app-server`，与 Codex 自己的 `/status` 是同一个调用）；凭据由 Codex 自己发送，
AI Usage 从不读取。Codex 查询不到时，显示 Codex 写进本地会话的最近一次套餐额度记录，并加以标注。
用 API Key 通过中转登录时，改为重放 CC Switch 已经为该服务商定义好的额度查询。所有来源都拿不到时，
用量和成本统计照常可看。

页面大约一秒内先显示额度卡；CodeBurn 算完默认周期后，用量报表随即补上。

## 安装

需要 Windows 10 或 Windows 11，以及 Node.js 22.13.0 或更高版本；推荐使用当前 LTS。
下面的命令还需要 Git。
没有 Git 时，可以下载仓库 ZIP，解压后运行 `install.bat`。

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

也可以双击 `install.bat`。安装器会固定已经审计过的 CodeBurn 和 ccusage 版本，
把运行文件复制到 `%LOCALAPPDATA%\ClaudeUsage`，并创建 **AI Usage** 桌面快捷方式。
以后打开快捷方式，就会生成一份新的用量快照。
请在普通、非提升权限的用户会话中运行安装器；这是按用户安装的工具，管理员权限运行会被拒绝。
CodeBurn 和 ccusage 会作为全局 npm 包安装，卸载 AI Usage 后仍会保留。安装器不会永久修改
PowerShell 执行策略。运行文件会先在同一用户目录内暂存和校验，并与所有 Windows 会话中正在
生成的报告协调；升级失败时会恢复此前的受管文件和 npm 包版本。安装器被中断时，其依赖
子进程也会一并终止；重新运行安装器可以修复未完成的事务或损坏的包清单，并清除安装器拥有的
中断残留。
双击运行的批处理入口会在失败时暂停，并保留 PowerShell 的退出码，避免错误随窗口一起消失。

## 隐私

- Claude Code、Codex 的会话存储，Claude Code 的 `~/.claude.json`，Claude 桌面版的套餐用量记录
  （含 MSIX 打包版应用包目录里的那份），
  Codex 的 `auth.json`（只读登录方式）以及 CC Switch 数据库都只会被读取。桌面版加密保存的登录
  信息从不打开。
- 提示词、工具参数、服务商地址、鉴权头和凭据不会进入浏览器载荷或日志。
- 正常启动会短暂保留临时报告文件，随后自动删除；遇到 Windows 文件占用会自动重试，
  仍未释放的残留会被标记，并在下次打开页面前优先清理。
- 跨运行保留的额度缓存包含额度状态和时间信息。Claude 缓存还会保存当前登录账号的不透明 SHA-256
  摘要，退出登录或切换账号后不会显示上一个账号的额度。Codex 缓存保存当前 CC Switch 服务商 ID
  与不透明的 SHA-256 配置指纹，防止切换服务商或原地修改密钥、端点、额度脚本后继续复用旧的
  新鲜缓存。两者都不保存原始令牌、API 密钥、账号标识、服务商地址或鉴权头。
- 官方 Codex 命令行响应额度查询时行为与平时一致，可能会刷新它自己的 `auth.json` 登录信息；
  AI Usage 本身从不写这个文件。
- 不会为了加速而缓存上一份完整报告；项目路径和会话标识仍然是用完即删的。

运行时有五条明确记录的网络路径。Claude 请求需要已登录的 Claude Code 命令行；Codex app-server
查询需要 ChatGPT 登录；中转请求需要 API Key 登录且 CC Switch 配置了额度查询；CodeBurn 使用默认
USD 显示币种时 Frankfurter 请求不会启用。

| 用途 | 目的地 | 发送内容 |
|---|---|---|
| 读取真实的 Claude 额度 | Anthropic OAuth 用量端点 | Claude Code 已有的 OAuth 令牌只放在鉴权头中，不发送会话内容或用量汇总 |
| 读取 ChatGPT 登录的 Codex 额度 | OpenAI，由官方 Codex 命令行（`codex app-server`）发起 | Codex 用自己的登录发出请求；AI Usage 从不读取或转发该凭据 |
| 读取中转的 Codex 额度 | CC Switch 本来就在查询的中转端点 | Codex 已有的 API 密钥只放在服务商声明且受白名单约束的凭据请求头中，不发送会话内容或用量汇总 |
| 刷新公开模型价格 | GitHub 原始文件和 models.dev | CodeBurn（每日缓存过期时）和 ccusage（每次启动）只请求公开价格目录，不发送凭据或用量数据 |
| 刷新非 USD 汇率 | Frankfurter 公开 API | 只发送目标 ISO 币种代码 |

所有凭据始终只读，不会进入快照、日志或错误信息，服务商地址同样不会写进快照。中转密钥只会
替换到已审计的请求头中，并且只能发送到 CC Switch 精确选中的 HTTPS 源；控制字符或跨服务商地址
会被拒绝。Codex 命令行和其他采集器一样运行在随句柄关闭即终止的 Job Object 中，并有独立的
30 秒预算。额度请求失败时，本地面板仍会显示。

## 工作方式

1. 隐藏启动器运行 `Generate-ClaudeReport.ps1`。
2. 没有互斥锁竞争且依赖预检正常时，浏览器会先于采集打开。额度查询立即开始，与 CodeBurn
   并行；CodeBurn 优先生成所选周期，ccusage 读取本地窗口数据并按最新公开价目计价。等待报告锁、
   公开价格或汇率冷缓存仍会增加耗时，页面不会掩盖这些情况。
3. 额度卡最先出现：本地记录约一秒内显示，实时来源返回后随即更新。两个服务商的报告完成后，
   默认周期的用量随即补上；其他周期和模型历史归属随后原子更新。只有在线模型合计对不上总额时，
   才会额外运行一次历史归属查询。
4. 页面只轮询到最终更新完成，正常启动随后删除临时文件。

如果第一次本地汇总就失败，加载页会立即提示失败，不再等到轮询超时；独立、原子且绑定本次运行的
失败信号，也能在最终快照持续写入失败时终止已经可用页面的轮询。提示中不会包含采集器输出或凭据细节。
失败页在无人重试时仍保留正常的浏览器读取窗口；再次打开快捷方式会请求有界的提前关闭，随后生成一份
新报告，而不会复用失败页面。

CodeBurn 每次只运行一个进程，因为它的报告命令不支持并发。按用户 SID 命名的全局 Windows 互斥锁会同时
保护单份报告里的调用和多个面板启动进程。报告仍在生成时再次打开快捷方式，会直接复用
当前页面，而不是再排队执行一轮汇总。每个采集器还会被原子创建在随句柄关闭即终止的 Windows Job Object
中；即使生成器被强制结束或崩溃，旧 CodeBurn/ccusage 进程也不会残留到下一次启动。超时或输出超限时，
生成器会等到整个 Job 进程树退出后才启动下一次 CodeBurn 调用。
如果无法确认进程树已经清空，本轮会立即拒绝后续采集器启动，并在释放互斥锁前执行保守的同用户进程扫描。
可选 ccusage 采集从进程启动起只有一个 120 秒预算和 16 MiB 输出上限，最终收集阶段不会重新获得一轮预算。

[架构文档](docs/ARCHITECTURE.md)记录了数据流、成本核对、币种处理、网络边界和设计决策。

## 常用命令

生成并保留调试快照。

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

命令会写入独立的 `%TEMP%\ClaudeUsage\debug-<时间戳>-<进程号>\` 目录，并且不会自动删除。
快照包含本地汇总和项目路径，分享以前需要先检查文件内容。

运行本地验证。

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\ReportData.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Static.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Generator.Integration.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\InstallJob.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Installer.Integration.Tests.ps1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Uninstaller.Integration.Tests.ps1
node .\tests\BrowserSmoke.mjs
```

卸载本地运行文件和快捷方式。

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 数据来源

- [CodeBurn](https://github.com/getagentseal/codeburn) 汇总 Claude 与 Codex 用量，并套用公开 API 参考价。
- [ccusage](https://github.com/ccusage/ccusage) 提供活动窗口的燃烧数据和 Claude 按小时分布。
- Anthropic OAuth 用量端点提供真实的 Claude 套餐额度；命令行未登录时，由 Claude Code 自己缓存的
  响应和 Claude 桌面版的套餐用量采样代替。
- 官方 Codex 命令行（`codex app-server`）提供 ChatGPT 登录的套餐额度；Codex 写进会话的
  `rate_limits` 作为本地兜底。
- CC Switch 提供其当前选中的 API Key 服务商的额度查询定义；它的数据库只读，不会被写入。

截图由 `tests/New-DemoSnapshot.ps1` 使用合成数据生成。

## 许可

[MIT](LICENSE)
