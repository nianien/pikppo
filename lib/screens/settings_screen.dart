import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../providers/model_service_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _hostController;
  late TextEditingController _nameController;
  List<String>? _availableModels;
  bool _isChecking = false;
  String? _connectionError;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _hostController = TextEditingController(text: appState.serviceHost);
    _nameController = TextEditingController(text: appState.userName);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isChecking = true;
      _connectionError = null;
    });

    // Save host first
    ref.read(appStateProvider.notifier).updateServiceHost(_hostController.text.trim());

    try {
      final service = ref.read(modelServiceProvider);
      if (service == null) {
        setState(() {
          _connectionError = '服务配置无效';
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
        // Auto-select first model if none selected
        final currentModel = ref.read(appStateProvider).currentModel;
        if (currentModel.isEmpty || !models.contains(currentModel)) {
          ref.read(appStateProvider.notifier).switchModel(models.first);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接成功，已选择 ${ref.read(appStateProvider).currentModel}')),
        );
      }
    } catch (e) {
      setState(() {
        _connectionError = '无法连接到本地模型服务，请检查服务是否启动';
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Model configuration section
          Text('本地模型配置',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),

          // Service type
          Text('服务类型', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ollama', label: Text('Ollama')),
              ButtonSegment(value: 'lmstudio', label: Text('LM Studio')),
            ],
            selected: {appState.serviceType},
            onSelectionChanged: (val) {
              final type = val.first;
              notifier.updateServiceType(type);
              _hostController.text =
                  type == 'ollama' ? 'http://10.0.2.2:11434' : 'http://10.0.2.2:1234';
              setState(() {
                _availableModels = null;
                _connectionError = null;
              });
            },
          ),
          const SizedBox(height: 12),

          // Host input
          TextField(
            controller: _hostController,
            decoration: InputDecoration(
              labelText: '服务地址',
              border: const OutlineInputBorder(),
              suffixIcon: _isChecking
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child:
                          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      onPressed: _checkConnection,
                      icon: const Icon(Icons.refresh),
                      tooltip: '检测连接',
                    ),
            ),
            onSubmitted: (_) => _checkConnection(),
          ),
          const SizedBox(height: 8),

          // Check connection button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isChecking ? null : _checkConnection,
              icon: const Icon(Icons.cable),
              label: Text(_isChecking ? '连接中...' : '检测连接'),
            ),
          ),

          if (_connectionError != null) ...[
            const SizedBox(height: 8),
            Text(_connectionError!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ],

          // Available models dropdown
          if (_availableModels != null && _availableModels!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('可用模型', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _availableModels!.contains(appState.currentModel)
                  ? appState.currentModel
                  : null,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '选择模型',
              ),
              items: _availableModels!
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
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
          ],

          if (appState.currentModel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading:
                    Icon(Icons.smart_toy, color: theme.colorScheme.primary),
                title: const Text('当前模型'),
                subtitle: Text(appState.currentModel),
              ),
            ),
          ],

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          // Personal info section
          Text('个人信息',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),

          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '姓名',
              border: OutlineInputBorder(),
            ),
            onChanged: (val) => notifier.updateUserName(val),
          ),
          const SizedBox(height: 12),

          Text('偏好语言', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '中文', label: Text('中文')),
              ButtonSegment(value: 'English', label: Text('English')),
            ],
            selected: {appState.preferredLanguage},
            onSelectionChanged: (val) =>
                notifier.updateLanguage(val.first),
          ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          // Data management
          Text('数据管理',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),

          OutlinedButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('记忆导出功能开发中')),
              );
            },
            icon: const Icon(Icons.download),
            label: const Text('导出记忆'),
          ),
          const SizedBox(height: 8),

          FilledButton.tonal(
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
                          backgroundColor: theme.colorScheme.error),
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
                Icon(Icons.delete_forever),
                SizedBox(width: 8),
                Text('清除全部记忆'),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
