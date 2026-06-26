import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 极简文本朗读封装——消息选择菜单"朗读"用。单例；每次朗读前先停掉上一段，
/// 避免叠读。按内容自动选语言（含中文 → zh-CN，否则 en-US）。
///
/// 注意：`flutter_tts` 是原生插件，**首次加入后必须整包重建**（停掉 App 重新
/// `flutter run`，仅热重载原生侧不会注册，调用会被 MissingPluginException 吞掉）。
/// 朗读还依赖设备装了对应语言的 TTS 语音数据（系统设置 → 文字转语音）。
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _inited = false;

  // CJK 统一表意文字区间（U+4E00–U+9FFF）：含中文则按 zh-CN 朗读。
  static final _cjk = RegExp(r'[一-鿿]');

  Future<void> _ensureInit() async {
    if (_inited) return;
    _inited = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      // iOS 需要共享实例才会在前台正常出声。
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _tts.setSharedInstance(true);
      }
    } catch (e) {
      debugPrint('tts init failed: $e');
    }
  }

  Future<void> speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _ensureInit();
    try {
      await _tts.stop();
    } catch (_) {}
    try {
      await _tts.setLanguage(_cjk.hasMatch(t) ? 'zh-CN' : 'en-US');
    } catch (e) {
      // 设备缺该语言语音数据时 setLanguage 可能失败——不阻断，用默认嗓音继续。
      debugPrint('tts setLanguage failed: $e');
    }
    try {
      final r = await _tts.speak(t);
      debugPrint('tts speak result: $r'); // 1=成功；0/异常多半是缺语音数据或没整包重建
    } catch (e) {
      debugPrint('tts speak failed: $e');
    }
  }

  Future<void> stop() => _tts.stop();
}
