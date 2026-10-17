// ArkTS(JS) 与 Dart 在**边界**上不一致的两个函数，统一在这里复刻。
//
// 为什么非要复刻：规则要和鸿蒙端算得**逐位相同**（判据是 shared/fixtures/*.json）。
// 直接照抄函数名会在少数输入上悄悄给出不同结果，而且这种差异极难在真机上发现。
//
// | ArkTS(JS)              | Dart 同名                  | 差异 |
// |------------------------|----------------------------|------|
// | Math.round(x)          | num.round()                | 正好 .5：JS 向 +∞，Dart 远离零 |
// | parseInt(s, 10)        | int.parse / int.tryParse   | JS 只解析前缀，Dart 抛错 / 返回 null |

/// 等价于 JS `Math.round`：`.5` 一律向 **+∞** 取整。
int jsRound(num x) => (x + 0.5).floor();

/// 等价于 JS `parseInt(s, 10)`：解析**前缀**数字，失败返回 null。
int? jsParseInt(String s) {
  final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}
