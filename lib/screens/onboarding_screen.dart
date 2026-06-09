import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state_provider.dart';
import '../theme/design_tokens.dart';

/// 启动页——只做品牌呈现和"开始使用"。
/// 不收集姓名/职业/兴趣等任何用户事实：那些应该在和角色对话中自然提及、由
/// 记忆归纳系统沉淀，硬塞表单与产品理念冲突。
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                const Spacer(flex: 2),
                Center(
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppPalette.brand,
                          AppPalette.brand.withValues(alpha: 0.8),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.xl),
                      boxShadow: [
                        BoxShadow(
                          color: AppPalette.brand.withValues(alpha: 0.35),
                          blurRadius: 32,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text('🌿', style: TextStyle(fontSize: 64)),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxxl),
                Text('你好 👋', style: theme.textTheme.headlineLarge),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '我是 pikppo',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  '一个会越用越懂你的私人 AI 管家。\n聊天间记忆会自然沉淀，无需先填表。',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(flex: 3),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => ref
                        .read(appStateProvider.notifier)
                        .completeOnboarding(),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('开始使用'),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
