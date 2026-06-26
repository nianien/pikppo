import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';
import 'app_toast.dart';

/// 输入栏"+"按钮：弹出附件面板（图片 / 视频 / 文件），选取后发送到当前会话。
class AttachmentButton extends ConsumerWidget {
  /// 非空 = 发到群聊；null = 发到当前角色私聊。
  final String? groupId;
  const AttachmentButton({super.key, this.groupId});

  Future<void> _send(
      WidgetRef ref, String type, String path, String name) async {
    try {
      await ref.read(appStateProvider.notifier).sendAttachment(
            type: type,
            sourcePath: path,
            name: name,
            groupId: groupId,
          );
    } catch (_) {
      showAppToast('附件发送失败，请重试', icon: Icons.error_outline);
    }
  }

  Future<void> _pickImage(WidgetRef ref) async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    await _send(ref, 'image', x.path, x.name);
  }

  Future<void> _takePhoto(WidgetRef ref) async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x == null) return;
    await _send(ref, 'image', x.path, x.name);
  }

  Future<void> _pickVideo(WidgetRef ref) async {
    final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    await _send(ref, 'video', x.path, x.name);
  }

  Future<void> _pickFile(WidgetRef ref) async {
    final result = await FilePicker.pickFiles();
    final f = result?.files.firstOrNull;
    if (f == null || f.path == null) return;
    await _send(ref, 'file', f.path!, f.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: '发送附件',
      icon: const Icon(Icons.add_circle_outline),
      onPressed: () {
        final scheme = Theme.of(context).colorScheme;
        showModalBottomSheet(
          context: context,
          backgroundColor: scheme.surfaceContainerHigh,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            // 微信式：浅灰底 + 4 列左对齐网格，每格白色方卡 + 细线图标。
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xl),
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.82,
                children: [
                  _AttachmentTile(
                    icon: Icons.photo_library_rounded,
                    label: '图片',
                    color: const Color(0xFF4C9AFF),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickImage(ref);
                    },
                  ),
                  _AttachmentTile(
                    icon: Icons.videocam_rounded,
                    label: '视频',
                    color: const Color(0xFFE89A4F),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickVideo(ref);
                    },
                  ),
                  _AttachmentTile(
                    icon: Icons.insert_drive_file_rounded,
                    label: '文件',
                    color: const Color(0xFF9B7BE0),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickFile(ref);
                    },
                  ),
                  _AttachmentTile(
                    icon: Icons.photo_camera_rounded,
                    label: '拍照',
                    color: const Color(0xFF3FB984),
                    onTap: () {
                      Navigator.pop(ctx);
                      _takePhoto(ref);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 附件面板里的单个圆形图标 + 标签（横排）。
class _AttachmentTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _AttachmentTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: Material(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(icon, size: 24, color: color),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 输入栏麦克风按钮：tap 开始/结束听写，识别文字实时写入 [controller]。
/// 系统识别服务不可用（部分国产 ROM 无内置识别器）时点按提示并保持禁用态。
class VoiceInputButton extends StatefulWidget {
  final TextEditingController controller;
  const VoiceInputButton({super.key, required this.controller});

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton> {
  final _stt = SpeechToText();
  bool _initialized = false;
  bool _available = true;
  bool _listening = false;

  /// 本次听写会话开始时输入框已有的文字——partial 结果在其后追加而非覆盖。
  String _baseText = '';

  Future<void> _toggle() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_initialized) {
      _available = await _stt.initialize(
        onError: (e) {
          if (!mounted) return;
          setState(() => _listening = false);
          // 没说话超时这类常规错误不打扰；权限/服务类错误给提示。
          if (e.permanent) {
            showAppToast('语音识别不可用：${e.errorMsg}',
                icon: Icons.mic_off_outlined);
          }
        },
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _listening = false);
          }
        },
      );
      _initialized = true;
      if (!mounted) return;
      setState(() {});
    }
    if (!_available) {
      showAppToast('当前设备没有可用的语音识别服务', icon: Icons.mic_off_outlined);
      return;
    }
    _baseText = widget.controller.text;
    setState(() => _listening = true);
    await _stt.listen(
      listenOptions: SpeechListenOptions(localeId: 'zh_CN'),
      onResult: (r) {
        final joined = _baseText.isEmpty
            ? r.recognizedWords
            : '$_baseText ${r.recognizedWords}';
        widget.controller.text = joined;
        widget.controller.selection =
            TextSelection.collapsed(offset: joined.length);
      },
    );
  }

  @override
  void dispose() {
    _stt.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _listening ? '停止听写' : '语音输入',
      icon: Icon(
        _listening ? Icons.mic : Icons.mic_none_outlined,
        color: _listening ? scheme.primary : null,
      ),
      onPressed: _toggle,
    );
  }
}
