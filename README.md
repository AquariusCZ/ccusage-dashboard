# AI Usage Ledger

一个面向 Windows 的本地、阅后即焚 AI 编程用量账本，同时汇总 **Claude Code** 与 **OpenAI Codex** 的调用、会话、Token、缓存、模型和项目数据。

![桌面端界面](docs/dashboard.png)

<p align="center"><img src="docs/mobile.png" width="390" alt="AI Usage Ledger mobile layout"></p>

## 特点

- Claude + Codex 统一视图与独立筛选
- 最近 30 天的调用、会话、Token、缓存命中率与项目排行
- 使用公开 API 价格进行参考估算，不冒充订阅套餐或实际账单
- 数据只在本机读取，不上传提示词、工具参数、密钥或会话正文
- 浏览器先打开加载页，统计完成后自动渲染
- 正常启动后自动删除 `%TEMP%\ClaudeUsage` 中的一次性快照
- 中文界面、明暗主题、桌面与移动端响应式布局

## 数据来源

- [CodeBurn](https://github.com/getagentseal/codeburn)：统一解析 Claude、Codex 等本地会话并计算 API 参考价
- [ccusage](https://github.com/ccusage/ccusage)：可选，用于补充 Claude 活跃 5 小时窗口

金额仅是公开 API 单价下的参考估算。订阅套餐、自定义网关、企业协议或中转服务的实际计费可能不同。

## 要求

- Windows 10 / 11
- Node.js LTS
- CodeBurn（安装脚本会自动安装）
- ccusage（安装脚本会自动安装，用于 Claude 活跃窗口）

## 安装

```powershell
git clone https://github.com/AquariusCZ/ccusage-dashboard.git
cd ccusage-dashboard
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

也可以双击 `install.bat`。安装器会：

1. 检查 Node.js；
2. 安装缺失的 `codeburn` 与 `ccusage`；
3. 将 `src/` 复制到 `%LOCALAPPDATA%\ClaudeUsage`；
4. 在桌面创建 `AI Usage Ledger` 快捷方式。

## 使用与开发

双击桌面上的 `AI Usage Ledger`。

在仓库内生成调试快照：

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\src\Generate-ClaudeReport.ps1 -NoLaunch -KeepFile
```

输出位于 `%TEMP%\ClaudeUsage\report.html` 和 `data.js`。

| 文件 | 作用 |
|---|---|
| `src/Generate-ClaudeReport.ps1` | 并行采集 Claude/Codex 数据，生成一次性快照 |
| `src/template.html` | 自包含的中文前端、图表、筛选和明暗主题 |
| `src/dashboard.vbs` | 无控制台窗口启动器 |
| `install.ps1` | 安装依赖、复制文件和创建桌面快捷方式 |
| `docs/ARCHITECTURE.md` | 数据流、隐私和运行边界 |

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

如果仓库本身位于 `%LOCALAPPDATA%\ClaudeUsage`，卸载器只删除运行副本，不会删除 `.git`、`src/`、文档或提交历史。

## English

AI Usage Ledger is a local, ephemeral Windows dashboard for Claude Code and OpenAI Codex usage. It reads existing local session metadata, estimates API-equivalent cost, opens instantly with a loading shell, and removes its temporary report after use. No prompt content, credentials, or session bodies are uploaded.

## License

[MIT](LICENSE)
