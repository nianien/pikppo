import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../providers/model_service_provider.dart';
import '../services/cloud_provider_catalog.dart';
import '../theme/design_tokens.dart';
import '../utils/user_facing_error.dart';
import 'app_toast.dart';

/// 聊天页 AppBar 里的当前模型胶囊——既是状态展示也是切换入口。
class ModelChip extends StatelessWidget {
  final String model;
  const ModelChip({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              model.isEmpty ? '选择模型' : model,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.expand_more,
              size: 15, color: scheme.onPrimaryContainer),
        ],
      ),
    );
  }
}

/// 对话中切换 provider / 模型的 bottom sheet。
///
/// 职责边界：**设置页管接入**（key / host），**这里只在已接入的范围内选用**：
/// - 上排 chips：已配置 key 的云端 provider（+ 当前在用的本地服务）
/// - 下方列表：选中 provider 的可用模型
/// 切换写回全局配置（serviceType / cloudProvider / currentModel），对所有会话生效。
Future<void> showModelSwitcherSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _ModelSwitcherSheet(),
  );
}

class _ProviderTile extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;
  const _ProviderTile(
      {required this.name, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.center,
        margin: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.xs, AppSpacing.xs),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.6)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          name,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.onPrimaryContainer : null,
              ),
        ),
      ),
    );
  }
}

class _ModelSwitcherSheet extends ConsumerStatefulWidget {
  const _ModelSwitcherSheet();

  @override
  ConsumerState<_ModelSwitcherSheet> createState() =>
      _ModelSwitcherSheetState();
}

class _ModelSwitcherSheetState extends ConsumerState<_ModelSwitcherSheet> {
  /// 当前面板里选中的 provider（cloud id 或 `'local'`）——初始为生效中的。
  late String _selected;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appStateProvider);
    _selected = s.serviceType == 'local' ? 'local' : s.cloudProvider;
  }

  /// 可切换的 provider：已配 key 的云端 + （当前在用本地推理时）本地服务。
  List<(String, String)> _options() {
    final keys = ref.watch(cloudApiKeysProvider);
    final serviceType =
        ref.watch(appStateProvider.select((s) => s.serviceType));
    return [
      if (serviceType == 'local') ('local', 'Ollama 本地'),
      for (final spec in cloudProviderCatalog.values)
        if ((keys[spec.id] ?? '').isNotEmpty) (spec.id, spec.shortName),
    ];
  }

  void _pick(String model) {
    Navigator.pop(context);
    final notifier = ref.read(appStateProvider.notifier);
    if (_selected == 'local') {
      notifier.switchModel(model);
    } else {
      notifier.switchCloudProviderAndModel(_selected, model);
    }
    showAppToast('已切换至 $model', icon: Icons.swap_horiz_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = _options();
    final appState = ref.watch(appStateProvider);
    final activeProvider =
        appState.serviceType == 'local' ? 'local' : appState.cloudProvider;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.xs, AppSpacing.xs),
              child: Row(
                children: [
                  Text('切换模型',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新模型列表',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    // 清缓存即触发重新拉取（providerModelsProvider 缓存未命中
                    // 自动走网络）。
                    onPressed: () => invalidateModelCache(ref, _selected),
                  ),
                ],
              ),
            ),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Text('还没有可用的模型服务，请先到设置页配置 API Key'),
              )
            else
              // 左右分栏：左列 provider，右列该家的模型，点左列联动右列。
              Flexible(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 124,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final (id, name) in options)
                            _ProviderTile(
                              name: name,
                              selected: _selected == id,
                              onTap: () =>
                                  setState(() => _selected = id),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: ref
                          .watch(providerModelsProvider(_selected))
                          .when(
                            loading: () => const Padding(
                              padding: EdgeInsets.all(AppSpacing.xl),
                              child: Center(
                                  child: CircularProgressIndicator()),
                            ),
                            error: (e, _) => Padding(
                              padding:
                                  const EdgeInsets.all(AppSpacing.md),
                              child: Text(
                                  '模型列表获取失败：${userFacingError(e)}',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                          color:
                                              theme.colorScheme.error)),
                            ),
                            data: (list) {
                              if (list.isEmpty) {
                                return const Padding(
                                  padding:
                                      EdgeInsets.all(AppSpacing.md),
                                  child: Text('该服务暂无可用模型'),
                                );
                              }
                              return ListView.builder(
                                shrinkWrap: true,
                                itemCount: list.length,
                                itemBuilder: (context, i) {
                                  final m = list[i];
                                  final selected =
                                      _selected == activeProvider &&
                                          m == appState.currentModel;
                                  return ListTile(
                                    dense: true,
                                    title: Text(m,
                                        overflow:
                                            TextOverflow.ellipsis),
                                    trailing: selected
                                        ? Icon(Icons.check_rounded,
                                            color: theme
                                                .colorScheme.primary)
                                        : null,
                                    selected: selected,
                                    onTap: () {
                                      if (selected) {
                                        Navigator.pop(context);
                                        return;
                                      }
                                      _pick(m);
                                    },
                                  );
                                },
                              );
                            },
                          ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
