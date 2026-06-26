import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../models/message.dart';
import '../theme/design_tokens.dart';
import 'app_toast.dart';

String formatFileSize(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 附件气泡内容：图片缩略图（点开全屏）、视频/文件卡片（系统应用打开）。
class AttachmentContent extends StatelessWidget {
  final Message message;
  final bool isUser;
  const AttachmentContent(
      {super.key, required this.message, required this.isUser});

  @override
  Widget build(BuildContext context) {
    final path = message.attachmentPath!;
    final exists = File(path).existsSync();
    if (!exists) return _MissingCard(name: message.attachmentName);

    return switch (message.attachmentType) {
      'image' => _ImageThumb(path: path),
      'video' => _FileCard(
          icon: Icons.play_circle_outline,
          name: message.attachmentName ?? '视频',
          size: message.attachmentSize,
          isUser: isUser,
          onTap: () => _open(path),
        ),
      _ => _FileCard(
          icon: Icons.insert_drive_file_outlined,
          name: message.attachmentName ?? '文件',
          size: message.attachmentSize,
          isUser: isUser,
          onTap: () => _open(path),
        ),
    };
  }

  Future<void> _open(String path) async {
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      showAppToast('没有能打开该文件的应用', icon: Icons.error_outline);
    }
  }
}

class _ImageThumb extends StatelessWidget {
  final String path;
  const _ImageThumb({required this.path});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _FullScreenImage(path: path)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Image.file(
          File(path),
          width: 220,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _MissingCard(name: '图片'),
        ),
      ),
    );
  }
}

class _FullScreenImage extends StatelessWidget {
  final String path;
  const _FullScreenImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(File(path)),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final int? size;
  final bool isUser;
  final VoidCallback onTap;
  const _FileCard({
    required this.icon,
    required this.name,
    required this.size,
    required this.isUser,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = isUser ? scheme.onPrimary : scheme.onPrimaryContainer;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: fg),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                if (size != null)
                  Text(formatFileSize(size),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: fg.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingCard extends StatelessWidget {
  final String? name;
  const _MissingCard({this.name});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined,
            color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        Text('${name ?? '文件'}（已清理）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
