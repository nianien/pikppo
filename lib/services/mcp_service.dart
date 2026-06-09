import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart';
import '../models/app_state.dart';
import '../models/calendar_event.dart';
import '../utils/time_format.dart';

/// pikppo-mcp 服务地址——**App 内置能力，不暴露给用户配置**。
/// 默认按平台自动选；CI / dev / QA 可通过 `--dart-define=MCP_HOST=...` 覆盖。
String get defaultMcpHost {
  const override = String.fromEnvironment('MCP_HOST');
  if (override.isNotEmpty) return override;
  return defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8000'
      : 'http://localhost:8000';
}

/// MCP client wrapper. Owns the underlying [Client], exposes a connection-state
/// stream, and provides typed helpers for the calendar tools we currently use.
///
/// Uses streamable-http transport (FastMCP default mount: `/mcp/`). The host
/// passed to [connect] should be the base URL, e.g. `http://10.0.2.2:8000`;
/// `/mcp/` is appended automatically when the path is missing.
class McpService {
  Client? _client;
  String? _connectedUrl;
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
  Future<void> connect(String host) async {
    if (_state == McpConnectionState.connecting) return;
    await disconnect();

    final url = _normalizeUrl(host);
    _connectedUrl = url;
    _setState(McpConnectionState.connecting, error: null);

    final config = McpClient.simpleConfig(
      name: 'pikppo',
      version: '1.0.0',
    );
    final transport = TransportConfig.streamableHttp(baseUrl: url);

    final result = await McpClient.createAndConnect(
      config: config,
      transportConfig: transport,
    );

    result.fold(
      (client) {
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
        _client = null;
        _tools = const [];
        _setState(McpConnectionState.error, error: err.toString());
      },
    );
  }

  Future<void> _refreshTools() async {
    final c = _client;
    if (c == null) return;
    try {
      final tools = await c.listTools();
      _tools = tools
          .map((t) => McpToolDescriptor(
                name: t.name,
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
  /// tools that return plain strings (e.g. `delete_calendar_event` → "已删除").
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

  // --- Calendar tools ---

  Future<List<CalendarEvent>> listEvents(
      {String? startDate, String? endDate}) async {
    final args = <String, dynamic>{};
    if (startDate != null) args['start_date'] = startDate;
    if (endDate != null) args['end_date'] = endDate;
    final raw = await callTool('list_calendar_events', args);
    return _parseEventList(raw);
  }

  Future<CalendarEvent?> getEvent(String eventId) async {
    final raw = await callTool('get_calendar_event', {'event_id': eventId});
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return CalendarEvent.fromJson(decoded.cast<String, dynamic>());
  }

  Future<CalendarEvent> createEvent(CalendarEvent event) async {
    final args = <String, dynamic>{
      'title': event.title,
      'date': fmtDate(event.date),
      if (event.time != null) 'time': event.time,
      if (event.endTime != null) 'end_time': event.endTime,
      if (event.description != null) 'description': event.description,
      if (event.reminderMinutes != null)
        'reminder_minutes': event.reminderMinutes,
    };
    final raw = await callTool('create_calendar_event', args);
    return CalendarEvent.fromJson(_decodeMap(raw));
  }

  Future<CalendarEvent> updateEvent(CalendarEvent event) async {
    final args = <String, dynamic>{
      'event_id': event.id,
      'title': event.title,
      'date': fmtDate(event.date),
      'time': event.time,
      'end_time': event.endTime,
      'description': event.description,
      'reminder_minutes': event.reminderMinutes,
    };
    final raw = await callTool('update_calendar_event', args);
    return CalendarEvent.fromJson(_decodeMap(raw));
  }

  Future<void> deleteEvent(String eventId) async {
    await callTool('delete_calendar_event', {'event_id': eventId});
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

  static Map<String, dynamic> _decodeMap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException('expected JSON object, got: $raw');
  }

  static List<CalendarEvent> _parseEventList(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((m) => CalendarEvent.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    return const [];
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
  final String description;
  final Map<String, dynamic> inputSchema;
  const McpToolDescriptor({
    required this.name,
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
