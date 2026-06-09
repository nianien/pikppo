import 'package:dio/dio.dart';
import '../services/mcp_service.dart';

/// 把任意异常映射成**适合给用户看的简短文案**。
///
/// 设计原则：
/// - 用户气泡 / SnackBar / banner **只展示** [userFacingError] 的结果，不要 `$e`。
/// - 原始异常对象通过 [debugReason] 落日志/上报，**永远不进 UI**。
/// - 文案按"用户能采取什么动作"分类：网络重试、检查配置、稍后再试、未知错。
String userFacingError(Object e) {
  if (e is DioException) {
    return _dioMessage(e);
  }
  if (e is McpUnavailableException) {
    return 'MCP 工具服务暂时不可用，请稍后再试';
  }
  if (e is McpToolException) {
    return '工具调用失败：${e.tool}';
  }
  if (e is UnsupportedError) {
    return '当前模型不支持此操作';
  }
  if (e is ArgumentError) {
    return '参数错误，请检查输入';
  }
  if (e is FormatException) {
    return '数据格式异常，请稍后再试';
  }
  return '请求失败，请稍后再试';
}

String _dioMessage(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return '请求超时，请检查网络后重试';
    case DioExceptionType.connectionError:
      return '无法连接到服务，请检查网络或服务地址';
    case DioExceptionType.badCertificate:
      return '安全证书校验失败';
    case DioExceptionType.cancel:
      return '请求已取消';
    case DioExceptionType.badResponse:
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) return 'API Key 无效或权限不足，请重新配置';
      if (code == 404) return '请求的资源不存在';
      if (code == 429) return '请求过于频繁，请稍后再试';
      if (code != null && code >= 500) return '服务端临时异常，请稍后再试';
      return '请求失败 (HTTP $code)';
    case DioExceptionType.unknown:
      return '网络异常，请稍后再试';
  }
}

/// 原始异常落日志时用的简短摘要——把 stack/header 等敏感信息排除。
String debugReason(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    return 'DioException(${e.type}${code != null ? ', http=$code' : ''})';
  }
  return e.runtimeType.toString();
}
