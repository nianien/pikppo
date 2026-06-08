import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_state.dart';
import '../providers/app_state_provider.dart';
import '../providers/model_service_provider.dart';
import '../theme/design_tokens.dart';
import 'memory_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _hostController;
  late TextEditingController _nameController;
  late TextEditingController _mcpHostController;
  // 两家云厂商各自独立持有 key，切换 provider 时输入框联动当前 provider 的 key。
  late TextEditingController _anthropicKeyController;
  late TextEditingController _geminiKeyController;
  List<String>? _availableModels;
  bool _isChecking = false;
  String? _connectionError;
  bool _showApiKey = false;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _hostController = TextEditingController(text: appState.serviceHost);
    _nameController = TextEditingController(text: appState.userName);
    _mcpHostController = TextEditingController(text: appState.mcpHost);
    _anthropicKeyController = TextEditingController(
      text: ref.read(anthropicApiKeyProvider) ?? '',
    );
    _geminiKeyController = TextEditingController(
      text: ref.read(geminiApiKeyProvider) ?? '',
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _nameController.dispose();
    _mcpHostController.dispose();
    _anthropicKeyController.dispose();
    _geminiKeyController.dispose();
    super.dispose();
  }

  TextEditingController get _activeApiKeyController =>
      ref.read(appStateProvider).cloudProvider == 'gemini'
          ? _geminiKeyController
          : _anthropicKeyController;

  /// 切服务类型 / provider 的副作用统一在此：同步 host 输入框、清掉旧的模型列
  /// 表和连接错误，让用户重新检测连接。
  void _afterProviderChange() {
    _hostController.text = ref.read(appStateProvider).serviceHost;
    setState(() {
      _availableModels = null;
      _connectionError = null;
    });
  }

  void _setServiceType(String type) {
    ref.read(appStateProvider.notifier).updateServiceType(type);
    _afterProviderChange();
  }

  void _setLocalProvider(String provider) {
    ref.read(appStateProvider.notifier).updateLocalProvider(provider);
    _afterProviderChange();
  }

  void _setCloudProvider(String provider) {
    ref.read(appStateProvider.notifier).updateCloudProvider(provider);
    _afterProviderChange();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isChecking = true;
      _connectionError = null;
    });

    final notifier = ref.read(appStateProvider.notifier);
    final appState = ref.read(appStateProvider);
    final type = appState.serviceType;
    final storage = ref.read(secureStorageProvider);
    if (type == 'cloud') {
      // Persist whichever provider's key is currently showing.
      if (appState.cloudProvider == 'gemini') {
        await saveGeminiApiKeyWith(
          storage: storage,
          key: _geminiKeyController.text.trim(),
          setKey: (v) =>
              ref.read(geminiApiKeyProvider.notifier).state = v,
        );
      } else {
        await saveAnthropicApiKeyWith(
          storage: storage,
          key: _anthropicKeyController.text.trim(),
          setKey: (v) =>
              ref.read(anthropicApiKeyProvider.notifier).state = v,
        );
      }
    }
    notifier.updateServiceHost(_hostController.text.trim());

    try {
      final service = ref.read(modelServiceProvider);
      if (service == null) {
        setState(() {
          _connectionError = type == 'cloud' ? '请先填写 API Key' : '服务配置无效';
          _isChecking = false;
        });
        return;
      }
      final models = await service.fetchModels();
      setState(() {
        _availableModels = models;
        _isChecking = false;
      });
      if (models.isNotEmpty && mounted) {
        final currentModel = ref.read(appStateProvider).currentModel;
        if (currentModel.isEmpty || !models.contains(currentModel)) {
          notifier.switchModel(models.first);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '连接成功，已选择 ${ref.read(appStateProvider).currentModel}',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _connectionError = '无法连接到模型服务，请检查配置';
        _isChecking = false;
      });
    }
  }

  Future<void> _reconnectMcp() async {
    await ref
        .read(appStateProvider.notifier)
        .reconnectMcp(host: _mcpHostController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xxxl,
        ),
        children: [
          _Section(
            title: '模型服务',
            subtitle: '选择并配置驱动对话的 LLM',
            children: [
              _Field(
                label: '服务类型',
                child: RadioGroup<String>(
                  groupValue: appState.serviceType,
                  // Radio 自身的点击通过 ancestor 走这里；InkWell 包住的标签
                  // 点击走 onPick——两路最终都调 _setServiceType。
                  onChanged: (v) {
                    if (v != null) _setServiceType(v);
                  },
                  child: Row(
                    children: [
                      _RadioOption<String>(
                        label: '本地',
                        value: 'local',
                        onPick: _setServiceType,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      _RadioOption<String>(
                        label: '云端',
                        value: 'cloud',
                        onPick: _setServiceType,
                      ),
                    ],
                  ),
                ),
              ),
              _Field(
                label: '提供方',
                child: appState.serviceType == 'local'
                    ? DropdownButtonFormField<String>(
                        initialValue: appState.localProvider,
                        items: const [
                          DropdownMenuItem(
                              value: 'ollama', child: Text('Ollama')),
                        ],
                        onChanged: (val) {
                          if (val != null) _setLocalProvider(val);
                        },
                      )
                    : DropdownButtonFormField<String>(
                        initialValue: appState.cloudProvider,
                        items: const [
                          DropdownMenuItem(
                              value: 'anthropic', child: Text('Anthropic')),
                          DropdownMenuItem(
                              value: 'gemini', child: Text('Gemini')),
                        ],
                        onChanged: (val) {
                          if (val != null) _setCloudProvider(val);
                        },
                      ),
              ),
              _Field(
                label: '服务地址',
                child: TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(),
                  onSubmitted: (_) => _checkConnection(),
                ),
              ),
              if (appState.serviceType == 'cloud')
                _Field(
                  label: appState.cloudProvider == 'gemini'
                      ? 'Google AI Studio API Key'
                      : 'Anthropic API Key',
                  child: TextField(
                    controller: _activeApiKeyController,
                    obscureText: !_showApiKey,
                    decoration: InputDecoration(
                      hintText: appState.cloudProvider == 'gemini'
                          ? 'AIza...'
                          : 'sk-ant-...',
                      suffixIcon: IconButton(
                        icon: Icon(_showApiKey
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _showApiKey = !_showApiKey),
                      ),
                    ),
                    onChanged: (val) {
                      final storage = ref.read(secureStorageProvider);
                      if (appState.cloudProvider == 'gemini') {
                        saveGeminiApiKeyWith(
                          storage: storage,
                          key: val.trim(),
                          setKey: (v) => ref
                              .read(geminiApiKeyProvider.notifier)
                              .state = v,
                        );
                      } else {
                        saveAnthropicApiKeyWith(
                          storage: storage,
                          key: val.trim(),
                          setKey: (v) => ref
                              .read(anthropicApiKeyProvider.notifier)
                              .state = v,
                        );
                      }
                    },
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _isChecking ? null : _checkConnection,
                  icon: _isChecking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cable_outlined, size: 18),
                  label: Text(_isChecking ? '连接中…' : '检测连接'),
                ),
              ),
              if (_connectionError != null)
                Text(
                  _connectionError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error),
                ),
              if (_availableModels != null &&
                  _availableModels!.isNotEmpty)
                _Field(
                  label: '可用模型',
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        _availableModels!.contains(appState.currentModel)
                            ? appState.currentModel
                            : null,
                    decoration: const InputDecoration(),
                    items: _availableModels!
                        .map((m) =>
                            DropdownMenuItem(value: m, child: Text(m)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        notifier.switchModel(val);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已切换至 $val')),
                        );
                      }
                    },
                  ),
                ),
              if (appState.currentModel.isNotEmpty)
                _ChipRow(
                  icon: Icons.smart_toy_outlined,
                  label: '当前模型',
                  value: appState.currentModel,
                ),
            ],
          ),
          _Section(
            title: 'MCP 工具服务',
            subtitle: '日历等外部工具的接入端',
            children: [
              _Field(
                label: '服务地址',
                child: TextField(
                  controller: _mcpHostController,
                  decoration: const InputDecoration(
                    hintText: 'http://localhost:8000（streamable-http）',
                  ),
                  onSubmitted: (_) => _reconnectMcp(),
                ),
              ),
              _McpStatusRow(
                mcpState: appState.mcpState,
                error: appState.mcpError,
                onReconnect: _reconnectMcp,
              ),
            ],
          ),
          _Section(
            title: '个人信息',
            children: [
              _Field(
                label: '姓名',
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(),
                  onChanged: (val) => notifier.updateUserName(val),
                ),
              ),
              _Field(
                label: '偏好语言',
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '中文', label: Text('中文')),
                    ButtonSegment(value: 'English', label: Text('English')),
                  ],
                  selected: {appState.preferredLanguage},
                  onSelectionChanged: (val) =>
                      notifier.updateLanguage(val.first),
                ),
              ),
            ],
          ),
          _Section(
            title: '记忆管理',
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const MemoryScreen()),
                    );
                  },
                  icon: const Icon(Icons.psychology_outlined, size: 18),
                  label: const Text('查看 / 编辑记忆'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('正在归纳，可能需要一会儿')),
                    );
                    await notifier.runMemorySummaryNow();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('记忆归纳完成')),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('立即归纳记忆'),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认清除'),
                        content: const Text('确定要清除所有记忆吗？此操作不可撤销。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () {
                              notifier.clearAllMemories();
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('所有记忆已清除')),
                              );
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('确认清除'),
                          ),
                        ],
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_forever_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('清除全部记忆'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _Section(
      {required this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                4, AppSpacing.md, 4, AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500)),
        ),
        child,
      ],
    );
  }
}

/// 单选项：Radio + 文字标签整体一个 InkWell，保证标签也是有效点击区域。
/// 群组状态由外层 [RadioGroup] 统一管理；本组件只负责呈现和点击转发。
class _RadioOption<T> extends StatelessWidget {
  final String label;
  final T value;
  final ValueChanged<T> onPick;

  const _RadioOption({
    required this.label,
    required this.value,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => onPick(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Radio<T>(
              value: value,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 2),
            Text(label, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _ChipRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: AppSpacing.xs),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onPrimaryContainer)),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _McpStatusRow extends StatelessWidget {
  final McpConnectionState mcpState;
  final String? error;
  final VoidCallback onReconnect;

  const _McpStatusRow({
    required this.mcpState,
    required this.error,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color, icon) = switch (mcpState) {
      McpConnectionState.connected => (
          '已连接',
          theme.colorScheme.primary,
          Icons.check_circle_outline_rounded
        ),
      McpConnectionState.connecting => (
          '连接中…',
          theme.colorScheme.tertiary,
          Icons.sync_rounded,
        ),
      McpConnectionState.error => (
          '连接失败',
          theme.colorScheme.error,
          Icons.error_outline_rounded
        ),
      McpConnectionState.disconnected => (
          '未连接',
          theme.colorScheme.outline,
          Icons.cloud_off_outlined
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: AppSpacing.xs),
              Text(label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color)),
              const Spacer(),
              TextButton.icon(
                onPressed: onReconnect,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重连'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ],
          ),
        ),
        if (error != null && mcpState == McpConnectionState.error)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
