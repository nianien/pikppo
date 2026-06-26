import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart';
import '../models/app_state.dart';

/// pikppo-mcp 服务地址——**App 内置能力，不暴露给用户配置**。
/// 默认指向已上线的云端网关；本地开发可用 `--dart-define=MCP_HOST=...` 覆盖
/// （如 Android 模拟器 `http://10.0.2.2:8000`）。
String get defaultMcpHost {
  const override = String.fromEnvironment('MCP_HOST');
  if (override.isNotEmpty) return override;
  return 'https://mcp.pikppo.com';
}

/// 预共享 Bearer token——pikppo-mcp 应用层 `BearerAuthMiddleware` 用它做常量时间
/// 比对，不匹配返回 401（非 GCP IAM，Cloud Run 本身是 allow-unauthenticated）。
/// 与各家 LLM key 同等处理：`--dart-define=MCP_TOKEN=...`（开发期从 `.env` 注入），
/// 永不入库。空串时不带 Authorization 头——本地裸跑的 MCP 不需要鉴权。
String get _mcpToken => const String.fromEnvironment('MCP_TOKEN');

/// 冷启动退避重试：首次尝试 + 3 次重试，间隔 1s / 2s / 4s。云端网关跑在 Cloud Run
/// scale-to-zero 上，冷启动通常数秒内就绪——这个窗口足够覆盖；全部失败才落 error。
const int _kMaxConnectAttempts = 4;
const List<Duration> _kConnectBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// MCP client wrapper. Owns the underlying [Client], exposes a connection-state
/// stream, and provides typed helpers for the calendar tools we currently use.
///
/// Uses streamable-http transport (FastMCP default mount: `/mcp/`). The host
/// passed to [connect] should be the base URL, e.g. `http://10.0.2.2:8000`;
/// `/mcp/` is appended automatically when the path is missing.
class McpService {
  Client? _client;
  String? _connectedUrl;
  /// 取消令牌：每次 connect / disconnect 自增。退避重试循环在每个 await 后比对，
  /// 不一致即放弃这一轮，避免覆盖一个更新的连接状态。
  int _connectGen = 0;
  final _stateController =
      StreamController<McpConnectionState>.broadcast();
  McpConnectionState _state = McpConnectionState.disconnected;
  String? _lastError;
  List<McpToolDescriptor> _tools = const [];

  Stream<McpConnectionState> get stateStream => _stateController.stream;
  McpConnectionState get state => _state;
  String? get lastError => _lastError;
  bool get isConnected => _state == McpConnectionState.connected;
  String? get connectedUrl => _connectedUrl;
  List<McpToolDescriptor> get tools => _tools;

  void _setState(McpConnectionState s, {String? error}) {
    _state = s;
    _lastError = error;
    _stateController.add(s);
  }

  /// Connect to an MCP server over streamable-http. The given [host] should be
  /// a base URL (e.g. `http://localhost:8000`); the FastMCP default mount path
  /// `/mcp/` is appended automatically when no path is present.
  ///
  /// 云端网关跑在 Cloud Run scale-to-zero 上——重装 / 久未用后首次 connect 会撞冷
  /// 启动（数秒），单次尝试几乎必然超时。这里做有界退避重试覆盖冷启动窗口，全部
  /// 失败才落 [McpConnectionState.error]，避免用户被迫手动 toggle 才连得上。
  Future<void> connect(String host) async {
    if (_state == McpConnectionState.connecting) return;
    await disconnect();

    final gen = ++_connectGen;
    final url = _normalizeUrl(host);
    _connectedUrl = url;
    _setState(McpConnectionState.connecting, error: null);

    final config = McpClient.simpleConfig(
      name: 'pikppo',
      version: '1.0.0',
    );
    final transport = TransportConfig.streamableHttp(
      baseUrl: url,
      headers: _mcpToken.isEmpty
          ? null
          : {'Authorization': 'Bearer $_mcpToken'},
    );

    Object? lastError;
    for (var attempt = 0; attempt < _kMaxConnectAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_kConnectBackoff[attempt - 1]);
        // 退避期间用户可能关了开关或又发起一次 connect——令牌变了就退出这一轮，
        // 不要覆盖更新的连接状态。
        if (gen != _connectGen) return;
      }

      // createAndConnect 可能抛异常（冷启动超时），而非返回 error fold——两种都当
      // 作这一轮失败，进入下一次退避重试。
      final Result<Client, Exception> result;
      try {
        result = await McpClient.createAndConnect(
          config: config,
          transportConfig: transport,
        );
      } catch (e) {
        lastError = e;
        debugPrint('mcp connect attempt ${attempt + 1} threw: $e');
        continue;
      }

      // 连上了但已被新一轮 connect / disconnect 取代——丢弃这个 client，不动状态。
      if (gen != _connectGen) {
        result.fold((client) {
          try {
            client.disconnect();
          } catch (_) {}
        }, (_) {});
        return;
      }

      var connected = false;
      result.fold(
        (client) {
          connected = true;
          _client = client;
          _setState(McpConnectionState.connected);
          client.onDisconnect.listen((_) {
            _client = null;
            _tools = const [];
            if (_state == McpConnectionState.connected) {
              _setState(McpConnectionState.disconnected);
            }
          });
          // Fetch the tool catalog in the background so the agent loop can use it.
          unawaited(_refreshTools());
        },
        (err) {
          lastError = err;
          debugPrint('mcp connect attempt ${attempt + 1} failed: $err');
        },
      );
      if (connected) return;
    }

    // 所有尝试都失败——仍是当前这轮才落 error，避免覆盖更新的状态。
    if (gen != _connectGen) return;
    _client = null;
    _tools = const [];
    _setState(McpConnectionState.error, error: lastError?.toString());
  }

  Future<void> _refreshTools() async {
    final c = _client;
    if (c == null) return;
    try {
      final tools = await c.listTools();
      debugPrint('mcp listTools ok: ${tools.length} tools');
      _tools = tools
          .map((t) => McpToolDescriptor(
                name: t.name,
                title: t.title,
                description: t.description,
                inputSchema: t.inputSchema,
              ))
          .toList();
    } catch (e) {
      debugPrint('mcp listTools failed: $e');
      _tools = const [];
    }
  }

  /// Returns the cached tool catalogue. Re-fetches if it's empty (e.g. between
  /// connect and the background list completing).
  Future<List<McpToolDescriptor>> ensureTools() async {
    if (_tools.isNotEmpty) return _tools;
    if (!isConnected) return const [];
    await _refreshTools();
    return _tools;
  }

  Future<void> disconnect() async {
    // 令牌自增：打断任何正在退避重试的 connect 循环（关开关 / 切换 host 时）。
    _connectGen++;
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        c.disconnect();
      } catch (e) {
        debugPrint('mcp disconnect error: $e');
      }
    }
    if (_state != McpConnectionState.disconnected) {
      _setState(McpConnectionState.disconnected);
    }
  }

  /// Generic tool call. Returns a JSON-decodable string.
  ///
  /// Spec 2025-06-18 introduced `structuredContent`; FastMCP puts dict/list
  /// returns there and may leave `content` empty. We prefer the structured
  /// payload (encoded back to JSON) and fall back to joined TextContent for
  /// tools that return plain strings.
  Future<String> callTool(String name,
      [Map<String, dynamic> args = const {}]) async {
    final c = _client;
    if (c == null) {
      throw const McpUnavailableException();
    }
    final result = await c.callTool(name, args);
    final text = result.content
        .whereType<TextContent>()
        .map((t) => t.text)
        .join();
    if (result.isError == true) {
      throw McpToolException(name, text.isEmpty ? 'tool error' : text);
    }
    final structured = result.structuredContent;
    if (structured != null) {
      // FastMCP wraps non-dict returns (e.g. list) under a "result" key — unwrap.
      if (structured.length == 1 && structured.containsKey('result')) {
        return jsonEncode(structured['result']);
      }
      return jsonEncode(structured);
    }
    return text;
  }

  // --- Helpers ---

  /// Accepts user-entered hosts:
  ///   `http://host:8000`       → `http://host:8000/mcp`  (默认 FastMCP 挂载点)
  ///   `http://host:8000/mcp`   → 不变
  ///   `http://host:8000/sse`   → `http://host:8000/mcp`  (老版本 SSE 迁移)
  ///   其他自定义路径           → 保留用户输入
  static String _normalizeUrl(String host) {
    var url = host.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/sse')) {
      return '${url.substring(0, url.length - 4)}/mcp';
    }
    final path = Uri.tryParse(url)?.path ?? '';
    if (path.isEmpty) return '$url/mcp';
    return url;
  }

  void dispose() {
    disconnect();
    _stateController.close();
  }
}

/// Lightweight projection of an MCP `Tool`. Carried directly into the Agent
/// loop where it gets translated to the model provider's tool schema (e.g.
/// Anthropic `tools[]`).
class McpToolDescriptor {
  final String name;

  /// MCP 工具的人类可读名（spec 2025-06-18 的 `title`，可空）。UI 展示"正在调用
  /// 工具"时本地映射缺失则回退到它（见 [toolDisplayName]）。不发给模型。
  final String? title;
  final String description;
  final Map<String, dynamic> inputSchema;
  const McpToolDescriptor({
    required this.name,
    this.title,
    required this.description,
    required this.inputSchema,
  });
}

class McpUnavailableException implements Exception {
  const McpUnavailableException();
  @override
  String toString() => 'MCP 服务未连接';
}

class McpToolException implements Exception {
  final String tool;
  final String message;
  const McpToolException(this.tool, this.message);
  @override
  String toString() => 'MCP 工具 $tool 调用失败: $message';
}
