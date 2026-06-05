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
  late TextEditingController _apiKeyController;
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
    _apiKeyController = TextEditingController(
      text: ref.read(anthropicApiKeyProvider) ?? '',
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _nameController.dispose();
    _mcpHostController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isChecking = true;
      _connectionError = null;
    });

    final notifier = ref.read(appStateProvider.notifier);
    final type = ref.read(appStateProvider).serviceType;
    if (type == 'cloud') {
      final key = _apiKeyController.text.trim();
      await saveAnthropicApiKeyWith(
        storage: ref.read(secureStorageProvider),
        key: key,
        setKey: (v) =>
            ref.read(anthropicApiKeyProvider.notifier).state = v,
      );
      notifier.updateServiceHost(_hostController.text.trim());
    } else {
      notifier.updateServiceHost(_hostController.text.trim());
    }

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
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'ollama', label: Text('Ollama')),
                    ButtonSegment(
                        value: 'lmstudio', label: Text('LM Studio')),
                    ButtonSegment(value: 'cloud', label: Text('云端')),
                  ],
                  selected: {appState.serviceType},
                  onSelectionChanged: (val) {
                    final type = val.first;
                    notifier.updateServiceType(type);
                    switch (type) {
                      case 'ollama':
                        _hostController.text = 'http://10.0.2.2:11434';
                        break;
                      case 'lmstudio':
                        _hostController.text = 'http://10.0.2.2:1234';
                        break;
                      case 'cloud':
                        _hostController.text =
                            'https://api.anthropic.com';
                        break;
                    }
                    setState(() {
                      _availableModels = null;
                      _connectionError = null;
                    });
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
                  label: 'Anthropic API Key',
                  child: TextField(
                    controller: _apiKeyController,
                    obscureText: !_showApiKey,
                    decoration: InputDecoration(
                      hintText: 'sk-ant-...',
                      suffixIcon: IconButton(
                        icon: Icon(_showApiKey
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(
                            () => _showApiKey = !_showApiKey),
                      ),
                    ),
                    onChanged: (val) => saveAnthropicApiKeyWith(
                      storage: ref.read(secureStorageProvider),
                      key: val.trim(),
                      setKey: (v) => ref
                          .read(anthropicApiKeyProvider.notifier)
                          .state = v,
                    ),
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
