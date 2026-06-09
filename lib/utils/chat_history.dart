import '../models/message.dart';

/// 给 LLM 的最近对话切片——按时间正序，最多 [n] 条。
/// 用 list slice 代替 `toList().reversed.take(n).toList().reversed.toList()`
/// 这种四步反转链，单次扫描完成。
List<Message> recentChatHistory(List<Message> sorted, {int n = 10}) {
  if (sorted.length <= n) return sorted;
  return sorted.sublist(sorted.length - n);
}

/// 在 [messages] 里找最后一条 isUser 消息的下标；没有则 -1。
int indexOfLastUser(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i].isUser) return i;
  }
  return -1;
}
