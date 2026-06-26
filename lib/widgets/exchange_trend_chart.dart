import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../theme/design_tokens.dart';

/// 汇率走势折线图（纯绘制，不含标题/涨跌幅等 chrome）。汇率页和聊天里的走势卡片
/// 共用同一套 fl_chart 配置——调用方负责外层高度与 header。
class ExchangeTrendChart extends StatelessWidget {
  /// y 值（每日汇率），与 [dates] 等长。
  final List<double> rates;

  /// x 轴标签（`YYYY-MM-DD`），与 [rates] 等长。
  final List<String> dates;
  final double minRate;
  final double maxRate;

  /// 区间起点汇率——画一条基准虚线，线在其上=升值、下=贬值。
  final double startRate;

  /// 涨跌幅（决定线色：涨绿跌红，与全 App success/danger 语义一致）。
  final double changePct;

  const ExchangeTrendChart({
    super.key,
    required this.rates,
    required this.dates,
    required this.minRate,
    required this.maxRate,
    required this.startRate,
    required this.changePct,
  });

  static String _fmtRate(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(2) : v.toStringAsFixed(4);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final up = changePct >= 0;
    final lineColor = up ? AppPalette.success : AppPalette.danger;
    final spots = <FlSpot>[
      for (var i = 0; i < rates.length; i++) FlSpot(i.toDouble(), rates[i]),
    ];
    final span = (maxRate - minRate).abs();
    final pad = span == 0 ? maxRate * 0.01 : span * 0.15;

    return LineChart(
      LineChartData(
        minY: minRate - pad,
        maxY: maxRate + pad,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: startRate,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.25),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: (rates.length / 4).ceilToDouble().clamp(1, 999),
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= dates.length) {
                  return const SizedBox.shrink();
                }
                final d = dates[i];
                final mmdd = d.length >= 10 ? d.substring(5) : d;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(mmdd,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItems: (items) => items.map((s) {
              final i = s.x.toInt();
              final date = (i >= 0 && i < dates.length) ? dates[i] : '';
              return LineTooltipItem(
                '$date\n${_fmtRate(s.y)}',
                TextStyle(
                    color: scheme.onInverseSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 12),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: lineColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}
