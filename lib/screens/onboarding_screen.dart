import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/memory.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';

const _uuid = Uuid();

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();
  final _occupation = TextEditingController();
  final _interests = TextEditingController();
  int _step = 0;

  static const _stepCount = 4;

  @override
  void dispose() {
    _name.dispose();
    _occupation.dispose();
    _interests.dispose();
    super.dispose();
  }

  void _next() {
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  void _finish() {
    final notifier = ref.read(appStateProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;

    final name = _name.text.trim();
    final occupation = _occupation.text.trim();
    final interests = _interests.text.trim();

    if (name.isNotEmpty) {
      notifier.updateUserName(name);
      notifier.addMemory(Memory(
        id: _uuid.v4(),
        type: 'semantic',
        content: '姓名：$name',
        timestamp: now,
        tags: const ['画像'],
      ));
    }
    if (occupation.isNotEmpty) {
      notifier.addMemory(Memory(
        id: _uuid.v4(),
        type: 'semantic',
        content: '职业：$occupation',
        timestamp: now,
        tags: const ['画像', '职业'],
      ));
    }
    if (interests.isNotEmpty) {
      notifier.addMemory(Memory(
        id: _uuid.v4(),
        type: 'semantic',
        content: '兴趣爱好：$interests',
        timestamp: now,
        tags: const ['画像', '兴趣'],
      ));
    }
    notifier.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.6),
            radius: 1.4,
            colors: [
              AppPalette.container.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.18 : 0.55),
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProgressDots(current: _step, total: _stepCount),
                const SizedBox(height: AppSpacing.xxl),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppDurations.normal,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _buildStep(theme),
                    ),
                  ),
                ),
                Row(
                  children: [
                    if (_step > 0)
                      TextButton(
                        onPressed: _back,
                        child: const Text('上一步'),
                      ),
                    const Spacer(),
                    if (_step > 0 && _step < _stepCount - 1)
                      TextButton(
                          onPressed: _next, child: const Text('跳过')),
                    const SizedBox(width: AppSpacing.xs),
                    FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 16),
                      ),
                      child: Text(
                        _step == _stepCount - 1 ? '开始使用' : '下一步',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(ThemeData theme) {
    switch (_step) {
      case 0:
        return const _Welcome();
      case 1:
        return _SingleField(
          title: '怎么称呼你？',
          subtitle: '助理会用这个名字来叫你。可以稍后在设置中修改。',
          controller: _name,
          hint: '例：小明',
        );
      case 2:
        return _SingleField(
          title: '做什么工作？',
          subtitle: '让职场助理更准确地理解你的领域和工作上下文。',
          controller: _occupation,
          hint: '例：B 端产品经理',
        );
      case 3:
        return _SingleField(
          title: '有什么兴趣？',
          subtitle: '生活助理会基于这些偏好给出更贴合的建议。',
          controller: _interests,
          hint: '例：摄影、跑步、科幻小说',
          maxLines: 3,
        );
      default:
        return const SizedBox();
    }
  }
}

class _ProgressDots extends StatelessWidget {
  final int current;
  final int total;
  const _ProgressDots({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: List.generate(total, (i) {
        final active = i <= current;
        return Expanded(
          child: AnimatedContainer(
            duration: AppDurations.normal,
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.only(
                right: i == total - 1 ? 0 : AppSpacing.xs),
            height: 4,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        );
      }),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.md),
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.7),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: 32,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Center(
              child: Text(
                '🤖',
                style: TextStyle(
                  fontSize: 64,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          '你好 👋',
          style: theme.textTheme.headlineLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '我是 pikppo',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          '一个会越用越懂你的私人 AI 管家。\n先认识一下？只问几个问题，每一题都可以跳过。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SingleField extends StatelessWidget {
  final String title;
  final String subtitle;
  final String hint;
  final TextEditingController controller;
  final int maxLines;

  const _SingleField({
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.controller,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.md),
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.sm),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        TextField(
          controller: controller,
          maxLines: maxLines,
          autofocus: true,
          style: theme.textTheme.titleMedium,
          decoration: InputDecoration(hintText: hint),
        ),
      ],
    );
  }
}
