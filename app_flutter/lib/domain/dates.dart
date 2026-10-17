// 日期小工具 —— 从 util/DateUtil.ets 移植（只搬课表要用的那几个）。
// 约定：日期字符串统一 'YYYY-MM-DD'，全程**本地时区**。

/// 'YYYY-MM-DD' → DateTime（当天 00:00）
DateTime parseDate(String s) {
  final y = int.tryParse(s.substring(0, 4)) ?? 1970;
  final m = int.tryParse(s.length >= 7 ? s.substring(5, 7) : '1') ?? 1;
  final d = int.tryParse(s.length >= 10 ? s.substring(8, 10) : '1') ?? 1;
  return DateTime(y, m, d);
}

String _pad2(int n) => n < 10 ? '0$n' : '$n';

String formatDate(DateTime d) =>
    '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// a - b，按"天"计（用本地日历日相减，避免夏令时/时区把小时数算进去）
int diffDays(DateTime a, DateTime b) {
  final am = DateTime(a.year, a.month, a.day).millisecondsSinceEpoch;
  final bm = DateTime(b.year, b.month, b.day).millisecondsSinceEpoch;
  return ((am - bm) / 86400000).round();
}

/// 1 = 周一 … 7 = 周日
int weekdayOf(DateTime d) => d.weekday; // Dart: 周一=1 … 周日=7

/// 分钟数 → 'HH:mm'
String minToHHmm(int min) => '${_pad2((min ~/ 60))}:${_pad2(min % 60)}';
