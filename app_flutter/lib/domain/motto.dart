// 首页标语（鸿蒙端 `data/Prefs.ets` 的 MOTTO_* 与两个换算函数，逐条照搬）。
//
// 三条约定：
//  1. **按显示宽度**限长（不是一个字符一格）：全角算 2、半角算 1，
//     所以 32 宽度 = 16 个汉字 或 32 个英文字母。
//  2. **空串 = 用默认标语**（"清空 + 保存" 就是恢复默认）。
//  3. 边界字符在两边必须完全一致，否则"鸿蒙端能存进去、安卓端被截掉"这种鬼问题会出现。

const String mottoDefault = '离线课表 · 待办 · 计划';

/// 显示宽度上限（鸿蒙端 MOTTO_MAX_UNITS）
const int mottoMaxUnits = 32;

/// 单个字符占几个宽度：全角 2、半角 1
int _charUnits(int code) {
  final fullWidth = (code >= 0x1100 &&
      (code <= 0x115F ||
          (code >= 0x2E80 && code <= 0xA4CF) ||
          (code >= 0xAC00 && code <= 0xD7A3) ||
          (code >= 0xF900 && code <= 0xFAFF) ||
          (code >= 0xFE30 && code <= 0xFE4F) ||
          (code >= 0xFF00 && code <= 0xFF60) ||
          (code >= 0xFFE0 && code <= 0xFFE6) ||
          (code >= 0x20000 && code <= 0x3FFFD)));
  return fullWidth ? 2 : 1;
}

/// 一段文字的显示宽度
int mottoUnits(String text) {
  var w = 0;
  for (var i = 0; i < text.length; i++) {
    w += _charUnits(text.codeUnitAt(i));
  }
  return w;
}

/// 按显示宽度截断（输入时就实时用它，不能只在保存时用）
String clampMottoUnits(String text) {
  var w = 0;
  var out = '';
  for (var i = 0; i < text.length; i++) {
    final u = _charUnits(text.codeUnitAt(i));
    if (w + u > mottoMaxUnits) break;
    w += u;
    out += text[i];
  }
  return out;
}

/// 读换算后的标语（空 → 默认；超宽 → 截断）
String normalMotto(String raw) {
  final t = clampMottoUnits(raw.trim());
  return t.isEmpty ? mottoDefault : t;
}
