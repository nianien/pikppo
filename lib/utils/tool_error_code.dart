/// LocalTool / 未来远程工具回灌给 LLM 的错误码词表。
///
/// 模型在跨工具学到统一的错误处理分支（"看到 not_found 就提议创建；看到
/// permission_denied 就引导用户授权"）。所有返回 `{ok: false, error: "..."}`
/// 的工具都应只用这里定义的 code。
abstract class ToolErrorCode {
  static const notFound = 'not_found';
  static const invalidInput = 'invalid_input';
  static const permissionDenied = 'permission_denied'; // OAuth / 系统权限类
  static const network = 'network';                     // 远程工具连不上
  static const rateLimited = 'rate_limited';
  static const quotaExhausted = 'quota_exhausted';
}
