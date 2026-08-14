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
- Codex 真实额度，取自官方限额或所用中转商自己的订阅窗口。
- Claude 与 Codex 的成本、占比、调用、会话、Token 和缓存使用情况。
- 近七天、近三十天和全部历史三个周期。
- 每日趋势、活跃日历、连续活跃天数和 Claude 按小时用量。
- 模型构成、项目排行、高用量会话和明细表格。
- 明暗主题、移动端布局、键盘导航和减少动态效果。

模型成本始终与顶部预估一致。无法归属的差额会列为**未归属成本**，不完整的 Token
总数会标成下限。

Codex 额度有两个来源。官方 Codex 会把 `rate_limits` 写进本地会话记录；中转服务商不会，
因此 AI Usage 改为重放 CC Switch 已经为该服务商定义好的额度查询，直接从中转商读取余额、
订阅窗口和重置时间。在 CC Switch 里切换服务商，这张卡片会跟着切换。两个来源都拿不到时，
用量和成本统计照常可看。

## 安装

需要 Windows 10 或 Windows 11，以及 Node.js LTS。下面的命令还需要 Git。
没有 Git 时，可以下载仓库 ZIP，解压后运行 `install.bat`。

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

也可以双击 `install.bat`。安装器会固定已经审计过的 CodeBurn 和 ccusage 版本，
把运行文件复制到 `%LOCALAPPDATA%\ClaudeUsage`，并创建 **AI Usage** 桌面快捷方式。
以后打开快捷方式，就会生成一份新的用量快照。
CodeBurn 和 ccusage 会作为全局 npm 包安装，卸载 AI Usage 后仍会保留。安装器不会永久修改
PowerShell 执行策略。

## 隐私

- Claude Code、Codex 的会话存储和 CC Switch 数据库都只会被读取。
- 提示词、工具参数、服务商地址、鉴权头和凭据不会进入浏览器载荷或日志。
- 正常启动会短暂保留临时报告文件，随后自动删除。
- 跨运行保留的额度缓存只包含额度状态和时间信息，不包含令牌或 API 密钥。

运行时有四条明确记录的网络路径。CodeBurn 使用默认 USD 显示币种时 Frankfurter 请求不会
启用；CC Switch 没有选中启用额度查询的中转服务商时，Codex 额度请求也不会启用。

| 用途 | 目的地 | 发送内容 |
|---|---|---|
| 读取真实的 Claude 额度 | Anthropic OAuth 用量端点 | Claude Code 已有的 OAuth 令牌只放在鉴权头中，不发送会话内容或用量汇总 |
| 读取真实的 Codex 额度 | CC Switch 本来就在查询的中转端点 | Codex 已有的 API 密钥只放在鉴权头中，不发送会话内容或用量汇总 |
| 刷新公开模型价格 | GitHub 原始文件 | 只请求公开价格目录，不发送凭据或用量数据 |
| 刷新非 USD 汇率 | Frankfurter 公开 API | 只发送目标 ISO 币种代码 |

两个凭据始终只读，不会进入快照、日志或错误信息，服务商地址同样不会写进快照。
额度请求失败时，本地面板仍会显示。

## 工作方式

1. 隐藏启动器运行 `Generate-ClaudeReport.ps1`。
2. CodeBurn 和 ccusage 汇总本地 Claude 与 Codex 元数据。
3. 生成器核对模型成本，加入真实的 Claude 与 Codex 额度，再写出最小化的临时快照。
4. 浏览器打开本地面板，正常启动随后删除临时文件。

CodeBurn 每次只运行一个进程，因为它的报告命令不支持并发。Windows 用户级互斥锁会同时
保护单份报告里的调用和多个面板启动进程。

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
```

卸载本地运行文件和快捷方式。

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 数据来源

- [CodeBurn](https://github.com/getagentseal/codeburn) 汇总 Claude 与 Codex 用量，并套用公开 API 参考价。
- [ccusage](https://github.com/ccusage/ccusage) 提供活动窗口的燃烧数据和 Claude 按小时分布。
- Anthropic OAuth 用量端点提供真实的 Claude 套餐额度。
- CC Switch 提供其当前选中的 Codex 服务商的额度查询定义；它的数据库只读，不会被写入。

截图由 `tests/New-DemoSnapshot.ps1` 使用合成数据生成。

## 许可

[MIT](LICENSE)
