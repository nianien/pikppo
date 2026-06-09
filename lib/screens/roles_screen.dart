import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../providers/model_service_provider.dart';
import '../models/role.dart';
import '../theme/design_tokens.dart';
import '../utils/color_hex.dart';
import 'chat_detail_screen.dart';
import 'group_chat_screen.dart';

class RolesScreen extends ConsumerWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('角色'),
        actions: [
          IconButton(
            onPressed: () => _showCreateGroupChat(context, ref),
            icon: const Icon(Icons.group_add_outlined),
            tooltip: '创建群聊',
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreateRoleScreen()),
              );
            },
            icon: const Icon(Icons.person_add_outlined),
            tooltip: '新建角色',
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        itemCount: appState.roles.length,
        itemBuilder: (context, index) {
          final role = appState.roles[index];
          final color = parseHexColor(role.color);
          return _RoleCard(
            role: role,
            color: color,
            onTap: () {
              notifier.switchRole(role.id);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatDetailScreen(role: role),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showCreateGroupChat(BuildContext context, WidgetRef ref) {
    final appState = ref.read(appStateProvider);
    final selected = <String>{};
    final nameController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Container(
              padding: EdgeInsets.only(
                top: 16,
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('创建群聊',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ),
                        TextButton(
                          onPressed: selected.length >= 2
                              ? () {
                                  final name = nameController.text.trim().isEmpty
                                      ? selected
                                          .map((id) => appState
                                              .getRoleById(id)
                                              ?.name ?? '')
                                          .join('、')
                                      : nameController.text.trim();
                                  final group = ref
                                      .read(appStateProvider.notifier)
                                      .createGroup(name, selected.toList());
                                  Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          GroupChatScreen(group: group),
                                    ),
                                  );
                                }
                              : null,
                          child: const Text('创建'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        hintText: '群聊名称（选填）',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text('选择至少2个角色组建群聊',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5))),
                  ),
                  const SizedBox(height: 8),
                  ...appState.roles.map((role) {
                    final color = parseHexColor(role.color);
                    final isSelected = selected.contains(role.id);
                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (val) {
                        setSheetState(() {
                          if (val == true) {
                            selected.add(role.id);
                          } else {
                            selected.remove(role.id);
                          }
                        });
                      },
                      secondary: CircleAvatar(
                        backgroundColor: color.withValues(alpha: 0.15),
                        child: Text(role.icon,
                            style: const TextStyle(fontSize: 22)),
                      ),
                      title: Text(role.name),
                      subtitle: Text(role.description),
                      activeColor: theme.colorScheme.primary,
                    );
                  }),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class CreateRoleScreen extends ConsumerStatefulWidget {
  const CreateRoleScreen({super.key});

  @override
  ConsumerState<CreateRoleScreen> createState() => _CreateRoleScreenState();
}

class _CreateRoleScreenState extends ConsumerState<CreateRoleScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _notesController = TextEditingController();
  final _promptController = TextEditingController();

  String _selectedEmoji = '💡';
  String _selectedColor = '#3B82F6';
  final Set<String> _selectedFields = {};
  String _style = '简洁直接';
  String _language = '中文';
  bool _isGenerating = false;
  bool _promptGenerated = false;

  static const _fieldOptions = [
    '工作汇报', '邮件撰写', '会议记录', '财务分析',
    '健康管理', '旅行规划', '学习辅导', '育儿咨询', '法律常识',
  ];
  static const _styleOptions = ['简洁直接', '详细周全', '轻松幽默', '严谨专业'];
  static const _languageOptions = ['中文', '英文', '中英混合'];

  static const _presetEmojis = [
    '💼', '🌿', '💰', '❤️', '📚', '🎨', '🎮', '🏠',
    '✈️', '🍳', '🏋️', '🎵', '📷', '🔧', '🐱', '🌍',
    '⚡', '🎯', '🧠', '💡',
  ];

  static const _presetColors = [
    '#3B82F6', '#22C55E', '#F97316', '#EF4444',
    '#8B5CF6', '#EC4899', '#06B6D4', '#F59E0B',
  ];

  Color _parseHex(String hex) {
    return Color(int.parse(hex.replaceFirst('#', '0xFF')));
  }

  Future<void> _generatePrompt() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入角色名称')),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      final currentModel =
          ref.read(appStateProvider.select((s) => s.currentModel));
      final modelSvc = ref.read(modelServiceProvider);

      if (modelSvc != null && currentModel.isNotEmpty) {
        final prompt =
            '请根据以下信息，为一个AI助理角色生成一段简洁的系统提示词（system prompt），'
            '要求：用第一人称，明确角色定位，体现回复风格，100-150字以内，中文。\n\n'
            '角色名称：${_nameController.text}\n'
            '专注领域：${_selectedFields.join("、")}\n'
            '回复风格：$_style\n'
            '回复语言：$_language\n'
            '特别说明：${_notesController.text}';

        final result = await modelSvc.chat([
          {'role': 'user', 'content': prompt},
        ], currentModel);

        _promptController.text = result;
      } else {
        _promptController.text =
            '我是${_nameController.text}，专注于${_selectedFields.join("、")}领域。'
            '我会以$_style的风格为你提供帮助，使用$_language回复。'
            '${_notesController.text.isNotEmpty ? _notesController.text : "随时为你服务。"}';
      }

      setState(() {
        _isGenerating = false;
        _promptGenerated = true;
      });
    } catch (e) {
      _promptController.text =
          '我是${_nameController.text}，专注于${_selectedFields.join("、")}领域。'
          '我会以$_style的风格为你提供帮助，使用$_language回复。'
          '${_notesController.text.isNotEmpty ? _notesController.text : "随时为你服务。"}';
      setState(() {
        _isGenerating = false;
        _promptGenerated = true;
      });
    }
  }

  void _saveRole() {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入角色名称')),
      );
      return;
    }
    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先生成角色Prompt')),
      );
      return;
    }

    final role = Role(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: _nameController.text.trim(),
      icon: _selectedEmoji,
      description: _descController.text.trim().isEmpty
          ? _selectedFields.join('、')
          : _descController.text.trim(),
      color: _selectedColor,
      systemPrompt: _promptController.text.trim(),
    );

    ref.read(appStateProvider.notifier).addRole(role);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('角色「${role.name}」创建成功')),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _notesController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('新建角色')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('基本信息',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '角色名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              decoration: const InputDecoration(
                labelText: '角色描述（一句话）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            Text('选择图标', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presetEmojis.map((emoji) {
                final isSelected = emoji == _selectedEmoji;
                return GestureDetector(
                  onTap: () => setState(() => _selectedEmoji = emoji),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      border: isSelected
                          ? Border.all(
                              color: theme.colorScheme.primary, width: 2)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            Text('选择颜色', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _presetColors.map((hex) {
                final color = _parseHex(hex);
                final isSelected = hex == _selectedColor;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = hex),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                  color: color.withValues(alpha: 0.5),
                                  blurRadius: 8)
                            ]
                          : null,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 18)
                        : null,
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),

            Text('角色画像',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),

            Text('专注领域（多选）', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _fieldOptions.map((field) {
                final isSelected = _selectedFields.contains(field);
                return FilterChip(
                  label: Text(field),
                  selected: isSelected,
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _selectedFields.add(field);
                      } else {
                        _selectedFields.remove(field);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            Text('回复风格', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _styleOptions.map((s) {
                return ChoiceChip(
                  label: Text(s),
                  selected: _style == s,
                  onSelected: (_) => setState(() => _style = s),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            Text('回复语言', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _languageOptions.map((l) {
                return ChoiceChip(
                  label: Text(l),
                  selected: _language == l,
                  onSelected: (_) => setState(() => _language = l),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '特别说明（选填）',
                hintText: '如「不要给我列清单，直接说结论」',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: _isGenerating ? null : _generatePrompt,
                child: _isGenerating
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('生成角色Prompt'),
              ),
            ),

            if (_promptGenerated) ...[
              const SizedBox(height: 16),
              Text('生成的Prompt（可编辑）',
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _promptController,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saveRole,
                  child: const Text('保存角色'),
                ),
              ),
            ],

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final Role role;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard(
      {required this.role, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Stack(
            children: [
              // Vertical color strip on the left as visual identity.
              Positioned(
                left: 0,
                top: 12,
                bottom: 12,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [color, color.withValues(alpha: 0.5)],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md + 6,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            color.withValues(alpha: 0.22),
                            color.withValues(alpha: 0.10),
                          ],
                        ),
                        borderRadius:
                            BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                            color: color.withValues(alpha: 0.28),
                            width: 0.5),
                      ),
                      alignment: Alignment.center,
                      child: Text(role.icon,
                          style: const TextStyle(fontSize: 26)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(role.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(role.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.4)),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius:
                            BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded,
                              size: 14, color: color),
                          const SizedBox(width: 4),
                          Text('聊天',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
