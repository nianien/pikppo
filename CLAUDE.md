# Pikppo - AI 私人管家 Flutter App

## 架构

Flutter App 本身就是 AI Agent：

```
Flutter App (内置 Agent)
  ├── 调多家 LLM API（对话、推理）
  │     - 云端：Anthropic Claude / Google Gemini
  │     - 本地：Ollama（开发期测试用，发布版主推云端）
  ├── 本地工具直接执行（in-process ToolRegistry，零延迟）
  └── 外部工具走 MCP Server（HTTP，凭据隔离）
```

- Flutter 端集成多家 LLM API，自动按所选模型路由（Anthropic / Gemini 走云、Ollama 走本地）
- Agent loop 在 Flutter 端实现：收到 `tool_use` 响应后，根据工具来源分流：
  - **本地工具**（`lib/services/tool_registry.dart`）→ Dart 函数直接执行
  - **MCP 工具**（`lib/services/mcp_service.dart`）→ HTTP 调 pikppo-mcp
- 工具执行结果喂回 LLM 继续 agent 推理，直到模型返回纯文本

## 本地数据（Flutter 端，drift + SQLCipher 加密）

App 自管的所有数据都在本地，不走 MCP：

- **角色** → drift `custom_roles` 表（自定义）+ 代码常量 `defaultRoles`（预置）
- **群组** → drift `groups` 表
- **消息** → drift `messages` 表（按 conversation 懒加载 + 分页）
- **记忆** → drift `memories` 表 + 后台 `MemorySummarizer` 周期归纳
- **日历 / 日程** → drift 日历表（`CalendarEventRows`），统一经 `CalendarRepository`
  （`lib/repositories/calendar_repository.dart`）写入——**UI（应用面板日历页）与
  LLM 工具（`calendar_create_event` 等，`lib/services/tools/calendar_tools.dart`）
  共享同一条本地路径**，含盖戳 / 软删 / reminder 调度。不走 MCP
- **用户配置 / 模型 settings** → SharedPreferences
- **API Key / OAuth 凭据** → `flutter_secure_storage`（iOS Keychain / Android EncryptedSharedPreferences）

## MCP Server（pikppo-mcp）

- 项目地址：`/Users/skyfalling/Workspace/experiments/pikppo-mcp`
- Git 仓库：`git@github.com:nianien/pikppo-mcp.git`
- 基于 FastAPI + MCP SDK (FastMCP)
- Transport：streamable-http，默认端口 8000

**定位**：**纯外部 API 网关 + 凭据持有方**。任何需要第三方 API Key 或
OAuth refresh token 的工具都必须经此中转——这类凭据放客户端等于泄露。

- **已接入**：汇率（`convert_currency` / `get_exchange_rate` / `get_exchange_trend`
  / `list_exchange_rates`）——当前唯一真正走 MCP 的功能，客户端在
  `lib/screens/exchange_screen.dart` 经 `callMcpTool` 调用
- **规划接入**：股票、天气、邮件——按"先简单的 API key 类，再 OAuth 重的"顺序
- **永远不会接入**：App 自管的本地数据（角色 / 群组 / 记忆 / 日历 / 用户配置等），
  那些走本地 ToolRegistry 或直接读 drift
- **注**：日历曾规划走 MCP，现已**本地化**（Phase 1，见上"本地数据"）。pikppo-mcp
  即便仍保留 calendar 工具，客户端也不再调用

### 客户端接入（鉴权）

线上 MCP 网关用**应用层预共享 Bearer token** 鉴权，**不是 GCP IAM**：

- 端点：`https://mcp.pikppo.com/mcp`（streamable-http）
- Header：`Authorization: Bearer <MCP_TOKEN>`，仅此一个，无其它
- 校验：服务端 `BearerAuthMiddleware`（`pikppo-mcp/src/app/auth.py`）用
  `secrets.compare_digest` 常量时间比对，不匹配返回 **401**——所以 401 是应用层
  拒绝，不是 Cloud Run IAM
- token 来源：Secret Manager `pikppo-auth-token`（`openssl rand -hex 32` 生成），
  注入容器环境变量 `MCP_AUTH_TOKEN`
- 客户端取值：`gcloud secrets versions access latest --secret pikppo-auth-token --project pikppo`，
  写进 `.env` 的 `MCP_TOKEN=`（与 5 个 LLM key 同等处理，经
  `--dart-define-from-file=.env` 注入，**永不入库**）；客户端在
  `lib/services/mcp_service.dart` 的 `connect()` 注入 Authorization 头，
  `MCP_TOKEN` 空串时不带头（兼容本地裸跑的无鉴权 MCP）

## 部署

- **开发期（本地 MCP）**：pikppo-mcp 本机跑（`uv run python -m pikppo_mcp` 或类似），
  用 `--dart-define=MCP_HOST=...` 覆盖默认 host 指向本地（Android 模拟器
  `http://10.0.2.2:8000`、其它 `http://localhost:8000`）；本地裸跑无需鉴权，
  `MCP_TOKEN` 留空即可
- **云端 MCP（默认）**：客户端 host 默认 `https://mcp.pikppo.com`，需带
  `MCP_TOKEN`（见上"客户端接入"）
- **Cloud Run 访问控制**：入站 = `allUsers` + `roles/run.invoker`
  （`--allow-unauthenticated`，平台层公开），访问控制由上面的应用层 Bearer token
  负责；**出站** = pikppo-mcp 调第三方（汇率等）时用 Workload Identity 绑定 service
  account 持有凭据——**不要再生成/下载 JSON service account key**，那是已经发生过
  的安全事件，参考 `feedback_production_grade.md`
