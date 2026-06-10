import 'package:flutter/material.dart';

/// 全局 ScaffoldMessenger key——绑在 [MaterialApp] 上，让 notifier / 后台
/// timer 等没有 [BuildContext] 的位置也能调起瞬时提示。
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// 展示一条瞬时反馈——成功 / 进度 / 自愈型错误等"看一眼即可"的消息。
///
/// **设计原则**：本方法只承载"无需用户后续动作"的提示。需要用户决策、重试
/// 或处理的错误应该**就近常驻在出错的操作旁边**带操作入口（见 [InfoBanner]），
/// 而不是用一闪而过的 Snackbar。
void showAppToast(
  String message, {
  IconData? icon,
  Duration duration = const Duration(seconds: 3),
}) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return; // MaterialApp 还没构建完
  // 上一条还浮着就压掉——避免重叠堆积。
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(message)),
        ],
      ),
      duration: duration,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
