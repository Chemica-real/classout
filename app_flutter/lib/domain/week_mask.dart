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
