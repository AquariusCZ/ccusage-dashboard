# AI Usage

*[English](README.md)*

一个 Windows 上的本地、阅后即焚 AI 编程用量面板。它读取 **Claude Code** 与 **OpenAI Codex**
已经存在本机的会话元数据，显示你真实的 Claude 套餐额度，用完自动删除自己生成的报告。

![桌面端界面](docs/dashboard.png)

<p align="center"><img src="docs/mobile.png" width="360" alt="AI Usage 窄屏布局"></p>

## 能看到什么

- **真实的 Claude 额度**，不是估算：5 小时会话窗口、7 天总额度，以及按模型限定的额度，
  全部来自你的账户。任意一条打满 100% 都会明确告警--因为按模型的额度可能已经耗尽，
  而总额度看起来还很健康。
- **Claude 与 Codex 并排对比**，可单独筛选任一家。
- **三个周期**可在浏览器里直接切换：近 7 天、近 30 天、全部。
- 每日成本走势、带连续天数统计的活跃度日历、时段分布圆盘、模型构成、项目排行。
- 明暗双主题，桌面与移动端自适应。

金额是 **API 参考价估算**。订阅套餐、自定义网关、企业协议、中转服务的实际计费都不同，
这个面板从不声称显示的是你的账单。

## 隐私

- 会话存储是只读输入，不回写任何内容。
- 提示词、工具参数、API 密钥、服务商地址、鉴权头一律不显示、不写入快照、不提交。
- `shellCommands` 被刻意从载荷中剔除：它是数据里最接近命令内容的字段。
- 生成的报告与数据文件在短暂读取窗口后自动删除。`-KeepFile` 仅用于调试。

### 唯一的一次网络请求

额度来自 `GET https://api.anthropic.com/api/oauth/usage`，使用 Claude Code 已经存在本机的
OAuth 令牌鉴权。这和 Claude Code 自己发的是同一个请求，用你自己的凭据读你自己的额度。
**没有任何会话内容、提示词或统计结果离开本机。** 令牌只读、不刷新、不回写，也绝不会出现在
快照、日志或错误信息里。请求失败或未登录时，面板会说明原因，其余内容仍完全由本地数据渲染。

## 数据来源

- [CodeBurn](https://github.com/getagentseal/codeburn)：统一解析 Claude、Codex 会话并套用公开 API 价格
- [ccusage](https://github.com/ccusage/ccusage)：提供活动窗口的燃烧率、预计花费和时段分布
- Claude OAuth 用量端点：提供套餐额度

## 环境要求

- Windows 10 / 11
- Node.js LTS
- CodeBurn 与 ccusage（安装脚本会自动补齐）

## 安装

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

也可以双击 `install.bat`。安装器会检查 Node.js、安装缺失的 CLI 依赖、把 `src/` 复制到
`%LOCALAPPDATA%\ClaudeUsage`，并在桌面创建 `AI Usage` 快捷方式。

运行目录、`Generate-ClaudeReport.ps1` 文件名、`ai-usage-ledger-theme` 偏好键都是早期
"只统计 Claude"版本遗留的兼容标识，不代表本应用只统计 Claude。

## 使用

双击桌面上的 **AI Usage**。

只生成快照、不打开浏览器：

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

产物在 `%TEMP%\ClaudeUsage\report.html` 与 `data.js`。

| 路径 | 作用 |
|---|---|
| `src/Generate-ClaudeReport.ps1` | 采集用量与额度，生成一次性快照 |
| `src/template.html` | 自包含前端：图表、筛选、明暗主题 |
| `src/dashboard.vbs` | 无控制台窗口的启动器 |
| `install.ps1` | 依赖安装、文件复制、桌面快捷方式 |
| `docs/ARCHITECTURE.md` | 数据流、隐私边界，以及几个值得知道的坑 |

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

当仓库本身位于 `%LOCALAPPDATA%\ClaudeUsage` 时，卸载器只删除运行副本，
`.git`、`src/`、文档和提交历史都不动。

## 给后续开发者的提醒

`docs/ARCHITECTURE.md` 里记了两个很容易被改回去的结论：

1. **CodeBurn 不是并发安全的。** 并行调用会让不同提供商的数据串台--`--provider codex`
   可能返回两家的模型合集，而它的 overview 仍是正确切分的。生成器因此串行调用 CodeBurn。
2. **判断"是否被限流"以 `limits[]` 为准。** 只看两个主窗口会漏掉一条已经耗尽的按模型额度。

`docs/` 下的截图全部由合成演示数据渲染，绝不来自真实会话记录。

## 许可

[MIT](LICENSE)
