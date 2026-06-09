import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// SQLCipher 数据库加密密钥在 [FlutterSecureStorage] 里的 key 名。
const _kDbKeyStorageKey = 'pikppo_db_cipher_key';

/// 取出 / 首次创建 SQLite 加密密钥。
///
/// - 首次启动：用 `Random.secure()` 生成 256-bit 密钥、base64 入安全存储。
///   iOS 走 Keychain，Android 走 EncryptedSharedPreferences（双因素硬件支持）。
/// - 之后启动：直接读出复用。**永远不写明文 / 不打日志**——密钥泄露就等同于
///   整个本地数据库明文。
Future<String> getOrCreateDbKey(FlutterSecureStorage storage) async {
  final existing = await storage.read(key: _kDbKeyStorageKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final key = _generateKey();
  await storage.write(key: _kDbKeyStorageKey, value: key);
  return key;
}

String _generateKey() {
  final rng = Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64Url.encode(bytes);
}
