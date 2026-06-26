import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_state_provider.dart';
import '../services/mcp_service.dart';
import '../theme/design_tokens.dart';
import '../utils/time_format.dart';
import '../utils/user_facing_error.dart';
import '../widgets/exchange_trend_chart.dart';

/// 汇率页：换算 + 趋势，数据全部直接走 MCP 工具（实时外部 API，不落本地库）。
/// - convert_currency：实时换算
/// - get_exchange_trend：区间每日走势（fl_chart 折线）
class ExchangeScreen extends ConsumerStatefulWidget {
  const ExchangeScreen({super.key});

  @override
  ConsumerState<ExchangeScreen> createState() => _ExchangeScreenState();
}

/// 常用币种（ISO 4217）——下拉用，避免为填选项去打 list_exchange_rates。
const _currencies = <String, String>{
  'USD': '美元',
  'CNY': '人民币',
  'EUR': '欧元',
  'JPY': '日元',
  'GBP': '英镑',
  'HKD': '港元',
  'AUD': '澳元',
  'CAD': '加元',
  'SGD': '新加坡元',
  'KRW': '韩元',
  'CHF': '瑞士法郎',
  'THB': '泰铢',
};

class _ExchangeScreenState extends ConsumerState<ExchangeScreen> {
  String _from = 'USD';
  String _to = 'CNY';
  final _amountCtrl = TextEditingController(text: '100');

  Timer? _debounce;

  // 换算态
  bool _converting = false;
  String? _convertError;
  _Conversion? _conversion;

  // 趋势态
  int _trendDays = 30;
  bool _trendLoading = false;
  String? _trendError;
  _Trend? _trend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convert();
      _loadTrend();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  double get _amount => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  /// 统一的 MCP 调用 + 兜底：未连接时触发一次重连并抛出友好错误。
  Future<String> _callTool(String name, Map<String, dynamic> args) async {
    try {
      return await ref
          .read(appStateProvider.notifier)
          .callMcpTool(name, args);
    } on McpUnavailableException {
      // 冷启动/未连：触发一次重连，让用户重试即可命中。
      unawaited(ref.read(appStateProvider.notifier).reconnectMcp());
      throw const McpUnavailableException();
    }
  }

  void _onInputChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _convert);
  }

  void _swap() {
    setState(() {
      final t = _from;
      _from = _to;
      _to = t;
    });
    _convert();
    _loadTrend();
  }

  Future<void> _convert() async {
    if (_from == _to) {
      setState(() {
        _conversion = _Conversion(
          rate: 1,
          converted: _amount,
          updatedAt: '',
        );
        _convertError = null;
        _converting = false;
      });
      return;
    }
    setState(() {
      _converting = true;
      _convertError = null;
    });
    try {
      final raw = await _callTool('convert_currency', {
        'from_currency': _from,
        'to_currency': _to,
        'amount': _amount,
      });
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _conversion = _Conversion(
          rate: (json['rate'] as num).toDouble(),
          converted: (json['converted'] as num).toDouble(),
          updatedAt: (json['updated_at'] as String?) ?? '',
        );
        _converting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _convertError = e is McpUnavailableException
            ? 'MCP 未连接，请稍后重试'
            : userFacingError(e);
        _converting = false;
      });
    }
  }

  Future<void> _loadTrend() async {
    if (_from == _to) {
      setState(() {
        _trend = null;
        _trendError = '相同币种无走势';
        _trendLoading = false;
      });
      return;
    }
    setState(() {
      _trendLoading = true;
      _trendError = null;
    });
    final now = DateTime.now();
    final start = now.subtract(Duration(days: _trendDays));
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    try {
      final raw = await _callTool('get_exchange_trend', {
        'from_currency': _from,
        'to_currency': _to,
        'start_date': fmt(start),
        'end_date': fmt(now),
      });
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final points = (json['points'] as List)
          .map((p) => _TrendPoint(
        date: p['date'] as String,
        rate: (p['rate'] as num).toDouble(),
      ))
          .toList();
      if (!mounted) return;
      setState(() {
        _trend = _Trend(
          points: points,
          startRate: (json['start_rate'] as num).toDouble(),
          endRate: (json['end_rate'] as num).toDouble(),
          minRate: (json['min_rate'] as num).toDouble(),
          maxRate: (json['max_rate'] as num).toDouble(),
          changePct: (json['change_pct'] as num).toDouble(),
        );
        _trendLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _trendError = e is McpUnavailableException
            ? 'MCP 未连接，请稍后重试'
            : userFacingError(e);
        _trendLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('汇率')),
      body: RefreshIndicator(
        onRefresh: () => Future.wait([_convert(), _loadTrend()]),
        child: ListView(
          // 下拉刷新需要列表始终可滚动，即使内容不满屏。
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxxl),
          children: [
            _buildConverter(context),
            const SizedBox(height: AppSpacing.lg),
            _buildTrend(context),
            const SizedBox(height: AppSpacing.lg),
            _buildQuickPairs(context),
          ],
        ),
      ),
    );
  }

  /// 常用币种对——填补底部留白，一键切换。用户可增删：每个 chip 带删除 x，
  /// 末尾"＋ 收藏当前"在当前对未收藏时出现。列表持久化在 AppState。
  Widget _buildQuickPairs(BuildContext context) {
    final theme = Theme.of(context);
    final favorites =
    ref.watch(appStateProvider.select((s) => s.exchangeFavoritePairs));
    final notifier = ref.read(appStateProvider.notifier);
    final currentPair = '$_from/$_to';
    final currentSaved = favorites.contains(currentPair);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
          child: Text('常用',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final pair in favorites)
              InputChip(
                label: Text(pair),
                selected: pair == currentPair,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onPressed: () => _selectPair(pair),
                onDeleted: () => notifier.removeExchangePair(pair),
              ),
            if (!currentSaved && _from != _to)
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('收藏当前'),
                visualDensity: VisualDensity.compact,
                onPressed: () => notifier.addExchangePair(_from, _to),
              ),
          ],
        ),
      ],
    );
  }

  /// 切到某个 `FROM/TO` 对并刷新换算 + 走势。
  void _selectPair(String pair) {
    final parts = pair.split('/');
    if (parts.length != 2) return;
    if (_from == parts[0] && _to == parts[1]) return;
    setState(() {
      _from = parts[0];
      _to = parts[1];
    });
    _convert();
    _loadTrend();
  }

  // ---- 换算区 ----

  Widget _buildConverter(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text('金额',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          TextField(
            controller: _amountCtrl,
            keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              // 货币前缀，明确金额是哪种币（随 from 切换）。
              prefixText: '$_from  ',
              prefixStyle: theme.textTheme.titleMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
              hintText: '0',
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 14),
            ),
            onChanged: (_) => _onInputChanged(),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(child: _currencyDropdown(_from, (v) {
                setState(() => _from = v);
                _convert();
                _loadTrend();
              })),
              IconButton(
                tooltip: '交换',
                onPressed: _swap,
                icon: const Icon(Icons.swap_horiz_rounded),
              ),
              Expanded(child: _currencyDropdown(_to, (v) {
                setState(() => _to = v);
                _convert();
                _loadTrend();
              })),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _buildConvertResult(context),
        ],
      ),
    );
  }

  Widget _currencyDropdown(String value, ValueChanged<String> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding:
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: _currencies.entries
          .map((e) => DropdownMenuItem(
        value: e.key,
        child: Text('${e.key} · ${e.value}',
            overflow: TextOverflow.ellipsis),
      ))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _buildConvertResult(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_converting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_convertError != null) {
      return Text(_convertError!,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.error));
    }
    final c = _conversion;
    if (c == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_fmtAmount(c.converted)} $_to',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '1 $_from = ${_fmtRate(c.rate)} $_to',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (c.rate > 0) ...[
          const SizedBox(height: 2),
          Text(
            '1 $_to = ${_fmtRate(1 / c.rate)} $_from',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (c.updatedAt.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text('更新于 ${fmtUpdatedAt(c.updatedAt)}',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
        ],
      ],
    );
  }

  // ---- 趋势区 ----

  Widget _buildTrend(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$_from / $_to 走势',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: AppSpacing.sm),
              _rangeChips(),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(height: 220, child: _buildTrendBody(context)),
        ],
      ),
    );
  }

  Widget _rangeChips() {
    return Wrap(
      spacing: 6,
      children: [7, 30, 90].map((d) {
        final selected = _trendDays == d;
        return ChoiceChip(
          label: Text('$d天'),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (_) {
            if (_trendDays == d) return;
            setState(() => _trendDays = d);
            _loadTrend();
          },
        );
      }).toList(),
    );
  }

  Widget _buildTrendBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_trendLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_trendError != null) {
      return Center(
        child: Text(_trendError!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.error)),
      );
    }
    final t = _trend;
    if (t == null || t.points.length < 2) {
      return Center(
        child: Text('暂无足够走势数据',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    return Column(
      children: [
        _trendSummary(context, t),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _trendChart(context, t)),
      ],
    );
  }

  Widget _trendSummary(BuildContext context, _Trend t) {
    final theme = Theme.of(context);
    final up = t.changePct >= 0;
    final color = up ? AppPalette.success : AppPalette.danger;
    return Row(
      children: [
        Icon(up ? Icons.trending_up : Icons.trending_down,
            size: 18, color: color),
        const SizedBox(width: 4),
        Text(
          '$_trendDays天 ${up ? '+' : ''}${t.changePct.toStringAsFixed(2)}%',
          style: theme.textTheme.titleSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            '低 ${_fmtRate(t.minRate)} · 高 ${_fmtRate(t.maxRate)}',
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _trendChart(BuildContext context, _Trend t) {
    // 折线绘制与聊天里的走势卡片共用 [ExchangeTrendChart]——本页只负责外层
    // 标题 / 区间选择 / 涨跌摘要等 chrome。
    return ExchangeTrendChart(
      rates: [for (final p in t.points) p.rate],
      dates: [for (final p in t.points) p.date],
      minRate: t.minRate,
      maxRate: t.maxRate,
      startRate: t.startRate,
      changePct: t.changePct,
    );
  }

  /// 汇率：整数 2 位，否则 4 位（0.1477 这类小汇率要精度）。
  String _fmtRate(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  /// 换算金额：按货币惯例固定 2 位 + 千分位（14.77、100,000.00）。
  String _fmtAmount(double v) {
    final s = v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    final intPart = s.substring(0, dot);
    final frac = s.substring(dot);
    final neg = intPart.startsWith('-');
    final digits = neg ? intPart.substring(1) : intPart;
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '${neg ? '-' : ''}$buf$frac';
  }
}

class _Conversion {
  final double rate;
  final double converted;
  final String updatedAt;
  _Conversion(
      {required this.rate, required this.converted, required this.updatedAt});
}

class _TrendPoint {
  final String date;
  final double rate;
  _TrendPoint({required this.date, required this.rate});
}

class _Trend {
  final List<_TrendPoint> points;
  final double startRate;
  final double endRate;
  final double minRate;
  final double maxRate;
  final double changePct;
  _Trend({
    required this.points,
    required this.startRate,
    required this.endRate,
    required this.minRate,
    required this.maxRate,
    required this.changePct,
  });
}
