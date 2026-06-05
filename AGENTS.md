# Pikppo - AI 私人管家 Flutter App

## 架构

Flutter App 本身就是 AI Agent：

```
Flutter App (内置 Agent)
  ├── 调 Codex API（对话、推理）
  └── 调 MCP Server（工具执行）
```

- Flutter 端集成 Codex API，负责对话和推理
- 收到 Codex 的 tool_use 响应后，通过 HTTP 调用 MCP Server 执行工具
- 将工具执行结果喂回 Codex 继续对话

## MCP Server

- 项目地址：`/Users/skyfalling/Workspace/experiments/pikppo-mcp`
- Git 仓库：`git@github.com:nianien/pikppo-mcp.git`
- 基于 FastAPI + MCP SDK (FastMCP)
- Transport：SSE / streamable-http，默认端口 8000
- 提供的工具：角色、日程、记忆、群组、用户配置管理
- MCP Server 职责纯粹，只负责工具执行，不包含 Agent 逻辑
