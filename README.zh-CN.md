# AI Usage

[![验证](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml/badge.svg)](https://github.com/AquariusCZ/ccusage-dashboard/actions/workflows/verify.yml)

*[English](README.md)*

Claude Code 和 OpenAI Codex 已经在电脑里留下了足够多的用量元数据。我做这个工具，
只想把几件每天都会碰到的事看清楚。最近用了多少，哪天最忙。Claude 的五小时和七天
额度还剩多少，Claude 与 Codex 各占多少。

AI Usage 会把这些本地记录整理成一张一次性 Windows 面板，也会读取真实的 Claude 套餐
额度。界面里的金额按公开 API 参考价估算，适合比较趋势，不能当作订阅或服务商账单。

![AI Usage 桌面端界面](docs/dashboard.png)

<p align="center"><img src="docs/mobile.png" width="360" alt="AI Usage 窄屏布局"></p>

## 打开以后能看到什么

- Claude 真实的五小时、七天额度窗口，账户返回按模型额度时也会一并显示。
- Claude 与 Codex 的合计和各自占比，也可以单独筛选一家。
- 近七天、近三十天和全部历史三个周期。
- 平滑的每日成本曲线、对数色阶活跃日历、连续活跃天数和按小时分布。
- 模型成本与顶部预估严格对齐的模型构成、项目排行、高用量会话与明细表格。
- 内置中日韩像素字体、明暗主题、移动端布局、键盘可访问图表和减少动态效果支持。

Codex 额度只有在服务商返回 `rate_limits` 时才能显示。许多自定义服务商不会下发这个字段，
面板会如实说明，本地用量和成本统计仍然可用。

## 快速安装

需要 Windows 10 或 Windows 11，以及 Node.js LTS。安装脚本会固定已经审计过的 CodeBurn
和 ccusage 版本，缺少或版本不符时会自动安装正确版本。

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

也可以双击 `install.bat`。安装器会把运行文件复制到 `%LOCALAPPDATA%\ClaudeUsage`，
并在桌面创建 **AI Usage** 快捷方式。CodeBurn 与 ccusage 会作为全局 npm 包安装，
卸载 AI Usage 后仍会保留。安装器不会永久修改 PowerShell 执行策略。
以后双击快捷方式，就会生成一份新的用量快照。

## 隐私与网络边界

Claude Code 和 Codex 的会话存储只会被读取。生成浏览器载荷以前，脚本会剔除提示词、
工具参数、服务商地址、鉴权头与 `shellCommands`。令牌和凭据不会进入快照，也不会写进日志。

正常启动会临时生成 `report.html`、`data.js` 和字体文件。浏览器获得一小段读取时间以后，
生成器会把这些文件删除。`%TEMP%\ClaudeUsage\quota-cache.json` 会跨运行保留，
额度请求失败时可显示上一次的百分比和重置时间。它不含令牌，卸载器会一并删除。
`-KeepFile` 只用于调试，每次保留的运行都会写进独立目录。

运行时最多有三条网络路径，项目把它们明确写在这里。CodeBurn 使用默认 USD 显示币种时，
第三条路径不会启用。

| 用途 | 目的地 | 发送内容 |
|---|---|---|
| 读取真实的 Claude 套餐额度 | Anthropic OAuth 用量端点 | Claude Code 已有的 OAuth 令牌只放在鉴权头中，不发送会话内容或用量汇总 |
| CodeBurn 的二十四小时价格缓存过期时刷新公开模型价格 | GitHub 原始文件 | 未鉴权的价格目录请求，不携带凭据、会话内容或用量汇总 |
| CodeBurn 选择非 USD 币种且二十四小时汇率缓存过期时刷新汇率 | Frankfurter 公开 API | 只发送目标 ISO 币种代码，不携带凭据、会话内容或用量汇总 |

生成器会拒绝未经复核的 CodeBurn 或 ccusage 版本，全局包升级不会悄悄扩大这条边界。

OAuth 令牌始终只读。AI Usage 不刷新、不回写，也不会把它放进错误信息和生成报告。
额度请求失败时，本地面板仍会正常显示。

## 它怎样工作

1. 隐藏启动器运行 `Generate-ClaudeReport.ps1`。
2. CodeBurn 统一解析 Claude 与 Codex 的会话元数据，并套用公开 API 参考价。
3. 生成器把 CodeBurn 的持久状态总额与当前仍可读取的模型明细合并，保留顶部总额，
   无法归属的差额会明确列出。
4. ccusage 提供当前 Claude 窗口的燃烧率、预计花费和按小时分布。
5. 生成器只保留界面真正会使用的汇总字段。
6. 浏览器读取本地载荷，正常启动随后清理临时文件。

CodeBurn 每次只运行一个进程。它的报告命令不支持并发，重叠扫描可能悄悄混入另一家
服务商的模型和项目记录。项目使用 Windows 用户级互斥锁，同时约束单份报告和多个启动进程。

CodeBurn 0.9.19 会持久保存概览成本，但旧会话文件无法继续读取后，模型级 Token 明细可能
不再完整。AI Usage 使用 CodeBurn 公开的本地状态输出，把模型成本核对到 `overview.cost`，
不会读取它的私有缓存。Token 不完整时按下限显示；状态结果缺失或被截断时，差额会列为
“其他未归属”，不会让模型合计悄悄低于顶部预估。
上游状态里的模型成本以 USD 保存，因此合并到已换算的 report 以前，AI Usage 会应用
CodeBurn 返回的汇率。默认仍是 USD；用户选择其他 CodeBurn 显示币种后，整个面板统一显示
该 ISO 币种代码。

## 保留调试快照

只生成报告、不打开浏览器时运行下面的命令。

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

命令会打印保留的 `report.html` 路径。每次运行使用独立的
`%TEMP%\ClaudeUsage\debug-<时间戳>-<进程号>\` 目录，后一次调试不会覆盖前一次。

## 数据来源

- [CodeBurn](https://github.com/getagentseal/codeburn) 统一解析 Claude 与 Codex 会话，并套用公开 API 参考价。
- [ccusage](https://github.com/ccusage/ccusage) 提供活动窗口的燃烧数据和按小时分布。
- Anthropic OAuth 用量端点提供 Claude 套餐额度。

## 项目结构

| 路径 | 作用 |
|---|---|
| `src/Generate-ClaudeReport.ps1` | 采集用量和额度数据，写出一次性快照 |
| `src/ReportData.psm1` | 合并持久模型成本、当前模型明细与保守降级结果 |
| `src/template.html` | 本地 HTML、CSS、JavaScript、图表、筛选和主题 |
| `src/fonts/` | 内置方舟与缝合像素 Web 字体及 OFL-1.1 许可证 |
| `src/dashboard.vbs` | 无控制台窗口的启动器 |
| `install.ps1` | 检查依赖、安装运行文件并创建桌面快捷方式 |
| `tests/` | 确定性合并测试、静态检查与保留快照核验 |
| `.github/workflows/verify.yml` | 在 Windows CI 中运行确定性测试与静态检查 |
| `docs/ARCHITECTURE.md` | 数据流、隐私边界、并发约束和设计决策 |

`%LOCALAPPDATA%\ClaudeUsage` 运行目录、`Generate-ClaudeReport.ps1` 文件名和
`ai-usage-ledger-theme` 偏好键来自早期只统计 Claude 的版本，目前作为兼容标识继续保留。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

仓库本身位于 `%LOCALAPPDATA%\ClaudeUsage` 时，卸载器只删除安装镜像。
Git 仓库、`src/`、文档和提交历史都会保留。

## 给后续开发者的提醒

- 判断 Claude 是否被限流时，以 `limits[]` 为准。按模型额度可能已经达到百分之百，
  两个主要窗口仍然看起来正常。
- CodeBurn 与 ccusage 保持在已经审计的版本。升级以前要重新检查运行行为和网络边界。
- 保持成本不变量：每个周期、每家服务商的模型成本之和必须等于 `overview.cost`；
  未知成本要明确列出，不完整 Token 要标成下限。
- 功能变化以后同步维护 `README.md` 与 `README.zh-CN.md`。
- `docs/` 里的截图只使用 `tests/New-DemoSnapshot.ps1` 生成的合成数据。真实路径、
  项目名称和额度状态都属于个人信息。

## 许可

[MIT](LICENSE)
