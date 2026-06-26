import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 附件私有副本管理。
///
/// 外部选取的文件**必须拷进应用文档目录**再引用：相册/下载目录的原件随时
/// 可能被系统或用户清掉，而 picker 返回的缓存路径在重启后失效。
class AttachmentStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'attachments'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 拷贝进库，返回私有副本。时间戳前缀防同名覆盖。
  static Future<File> import(String sourcePath) async {
    final dir = await _dir();
    final name = p.basename(sourcePath);
    final target =
        p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}_$name');
    return File(sourcePath).copy(target);
  }

  /// 删除私有副本（消息删除时调用）。文件不存在视为已清理，静默成功。
  static Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
    }
  }
}
