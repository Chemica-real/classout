// 周次掩码 —— 从 model/WeekMask.ets 移植。
//
// 掩码是长度 = 学期总周数的 '0'/'1' 字符串，第 1 个字符对应第 1 教学周。
// 例：16 周全上 = '1111111111111111'；1-8 周 = '1111111100000000'。

/// 第 [week] 周（从 1 开始）是否命中掩码
bool maskHas(String mask, int week) {
  if (week < 1 || week > mask.length) return false;
  return mask[week - 1] == '1';
}

String maskAll(int totalWeeks) => List<String>.filled(totalWeeks, '1').join();

String maskNone(int totalWeeks) => List<String>.filled(totalWeeks, '0').join();

bool maskIsEmpty(String mask) => !mask.contains('1');

// ---------------- 掩码 ↔ 人类可读文本（CourseManager 的「周次」输入框用） ----------------
//
// 与 `model/WeekMask.ets` 逐行对齐（fixtures/week_mask 里对拍）。
// 支持：'1-16'、'1-16单'、'2-16双'、'5'、'1-15(单)'、逗号分隔多段；
// 解析不出来时返回**全 1**（宁可全上，也不要静默丢课）。

String maskFromText(String text, int totalWeeks) {
  final chars = List<String>.filled(totalWeeks, '0');
  final normalized = text
      .replaceAll(RegExp(r'[（(]'), ' ')
      .replaceAll(RegExp(r'[）)]'), ' ')
      .replaceAll(RegExp(r'[、，;；]'), ',')
      .replaceAll('周', '')
      .trim();
  if (normalized.isEmpty) return maskAll(totalWeeks);

  var matched = false;
  for (final rawPart in normalized.split(',')) {
    var body = rawPart.trim();
    if (body.isEmpty) continue;
    var parity = 0; // 0 = 不限，1 = 单周，2 = 双周
    if (body.contains('单')) {
      parity = 1;
      body = body.replaceAll('单', ' ');
    } else if (body.contains('双')) {
      parity = 2;
      body = body.replaceAll('双', ' ');
    }
    body = body.trim();

    int from;
    int to;
    final dash = body.indexOf('-');
    if (dash > 0) {
      from = int.tryParse(body.substring(0, dash).trim()) ?? -1;
      to = int.tryParse(body.substring(dash + 1).trim()) ?? -1;
    } else {
      from = int.tryParse(body) ?? -1;
      to = from;
    }
    if (from < 0 || to < 0) continue;
    matched = true;
    if (to < from) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    for (var w = from; w <= to; w++) {
      if (w < 1 || w > totalWeeks) continue;
      if (parity == 1 && w.isEven) continue;
      if (parity == 2 && w.isOdd) continue;
      chars[w - 1] = '1';
    }
  }
  if (!matched) return maskAll(totalWeeks);
  return chars.join();
}

/// 掩码 → '1-8、10-16'；全 0 → '不上课'
String maskToText(String mask) {
  final ranges = <String>[];
  var start = -1;
  for (var i = 0; i <= mask.length; i++) {
    final on = i < mask.length && mask[i] == '1';
    if (on && start < 0) {
      start = i;
    } else if (!on && start >= 0) {
      final from = start + 1;
      final to = i;
      ranges.add(from == to ? '$from' : '$from-$to');
      start = -1;
    }
  }
  if (ranges.isEmpty) return '不上课';
  return ranges.join('、');
}
