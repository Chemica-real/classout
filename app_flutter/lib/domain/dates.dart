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

String formatDate(DateTime d) => '${d.year}-${_pad2(d.month)}-${_pad2(d.day)}';

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// a - b，按"天"计（用本地日历日相减，避免夏令时/时区把小时数算进去）
int diffDays(DateTime a, DateTime b) {
  final am = DateTime(a.year, a.month, a.day).millisecondsSinceEpoch;
  final bm = DateTime(b.year, b.month, b.day).millisecondsSinceEpoch;
  return ((am - bm) / 86400000).round();
}

/// 「周一」…「周日」里的那个字（鸿蒙端 `WEEKDAY_CN`）
const List<String> weekdayCn = ['一', '二', '三', '四', '五', '六', '日'];

/// 1 = 周一 … 7 = 周日
int weekdayOf(DateTime d) => d.weekday; // Dart: 周一=1 … 周日=7

/// 分钟数 → 'HH:mm'
String minToHHmm(int min) => '${_pad2((min ~/ 60))}:${_pad2(min % 60)}';

/// 'HH:mm' → 分钟数（解析不出来返回 null；与 ArkTS `hhmmToMin` 的 NaN 对应）
int? hhmmToMin(String s) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

// ---------------- 文案（与鸿蒙端逐字一致）----------------

/// 相对今天的自然语言：今天 / 明天 / 后天 / N 天后 / 逾期 N 天
String relativeDayText(DateTime target, DateTime from) {
  final d = diffDays(target, from);
  if (d == 0) return '今天';
  if (d == 1) return '明天';
  if (d == 2) return '后天';
  if (d > 0) return '$d 天后';
  return '逾期 ${-d} 天';
}

/// 'M.D'（用于 %D 变量）
String monthDayText(DateTime d) => '${d.month}.${d.day}';

/// 考试倒计时文案；[from] 显式传入，保证是纯函数（能进 fixtures）
String countdownText(DateTime target, DateTime from) {
  final d = diffDays(target, from);
  if (d > 1) return '还有 $d 天';
  if (d == 1) return '明天';
  if (d == 0) return '就是今天';
  return '已结束 ${-d} 天';
}

/// 最近的周一：周一原样、周二往回 1、周四往回 3、周五往后 3、周日往后 1
DateTime nearestMonday(DateTime d) {
  final wd = weekdayOf(d); // 1..7
  switch (wd) {
    case 1:
      return DateTime(d.year, d.month, d.day);
    case 2:
      return addDays(d, -1);
    case 3:
      return addDays(d, -2);
    case 4:
      return addDays(d, -3);
    case 5:
      return addDays(d, 3);
    case 6:
      return addDays(d, 2);
    default:
      return addDays(d, 1);
  }
}

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

String todayStr() => formatDate(today());
