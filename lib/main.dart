import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/app_state_provider.dart';
import 'providers/notification_service_provider.dart';
import 'screens/chat_detail_screen.dart';
import 'screens/chat_list_screen.dart';
import 'screens/roles_screen.dart';
import 'screens/apps_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/onboarding_screen.dart';
import 'theme/app_theme.dart';
import 'theme/design_tokens.dart';
import 'widgets/app_toast.dart';

/// 全局 NavigatorKey——通知 tap 在任何屏幕都可能触发，用全局 key 直推。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 三方库内部 unawaited future 的异常（如 mcp_client 的 transport 断连）在
  // 调用方无法捕获，只能在 zone 顶层兜底——记日志放行，不让 App 崩溃。
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught async error (non-fatal): $error');
    return true;
  };
  runApp(const ProviderScope(child: ButlerApp()));
}

class ButlerApp extends StatelessWidget {
  const ButlerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pikppo',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      navigatorKey: navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: const _AppRoot(),
    );
  }
}

class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  bool _consumedColdLaunch = false;

  @override
  void initState() {
    super.initState();
    // 通知初始化——可重入；onTap 是热场景（App 在跑），冷启动 payload 由
    // NotificationService.takePendingDeepLink 在 ready 后取。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notif = ref.read(notificationServiceProvider);
      notif.init(onTap: _handleNotificationTap);
    });
  }

  /// 热场景 tap：App 已在运行，直接跳转。
  void _handleNotificationTap(String eventId, String roleId) {
    final state = ref.read(appStateProvider);
    if (!state.isReady) return; // 未就绪等冷启动逻辑兜底
    final role = state.getRoleById(roleId);
    if (role == null) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    // 先回到 MainShell（pop 掉可能堆栈里的旧 ChatDetail），再推新的。
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(builder: (_) => ChatDetailScreen(role: role)));
  }

  /// 冷启动 tap：用户点通知拉起 App。AppStateNotifier ready 后取一次
  /// pending payload，跳到对应角色。仅消费一次。
  void _maybeConsumeColdLaunch() {
    if (_consumedColdLaunch) return;
    final state = ref.read(appStateProvider);
    if (!state.isReady) return;
    final notif = ref.read(notificationServiceProvider);
    final pending = notif.takePendingDeepLink();
    if (pending == null) {
      _consumedColdLaunch = true; // 没 pending 也只查一次
      return;
    }
    _consumedColdLaunch = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleNotificationTap(pending.eventId, pending.roleId);
    });
  }

  @override
  Widget build(BuildContext context) {
    // _loadState 跑完前显示 splash——杜绝"欢迎页一闪而过"和"发送被默认 state 抢跑覆盖"。
    final ready = ref.watch(appStateProvider.select((s) => s.isReady));
    if (!ready) return const _Splash();
    _maybeConsumeColdLaunch();
    final completed =
        ref.watch(appStateProvider.select((s) => s.onboardingCompleted));
    return completed ? const MainShell() : const OnboardingScreen();
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.bg,
      body: Center(
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: AppPalette.brand,
            borderRadius: BorderRadius.circular(22),
          ),
          alignment: Alignment.center,
          child: const Text('🌿', style: TextStyle(fontSize: 44)),
        ),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  final _screens = const [
    ChatListScreen(),
    RolesScreen(),
    AppsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: DecoratedBox(
        // 顶部 hairline——把底栏与内容区轻轻分开，避免悬浮感。
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withValues(alpha: 0.4),
              width: 0.6,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: '聊天',
            ),
            NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              selectedIcon: Icon(Icons.groups_rounded),
              label: '角色',
            ),
            NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps_rounded),
              label: '应用',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
