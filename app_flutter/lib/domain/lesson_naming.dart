// 虚拟课时命名模板（鸿蒙 `domain/LessonNaming.ets` 的 Dart 版）。
// %n 课程全名 / %c 简称（空则全名）/ %N 第几讲；%% 转义；
// 未知变量原样保留，方便用户看到写错的地方。

const String lessonTitleDefault = '%c 第 %N 讲';
const List<String> lessonTitleVars = ['n', 'c', 'N'];
const List<String> lessonTitleVarLabels = ['%n 全名', '%c 简称', '%N 第几讲'];

String renderLessonTitle(
    String template, String fullName, String shortName, int seq) {
  final short = shortName.isNotEmpty ? shortName : fullName;
  var out = '';
  for (var i = 0; i < template.length; i++) {
    final ch = template[i];
    if (ch != '%' || i + 1 >= template.length) {
      out += ch;
      continue;
    }
    final code = template[i + 1];
    if (code == 'n') {
      out += fullName;
      i++;
    } else if (code == 'c') {
      out += short;
      i++;
    } else if (code == 'N') {
      out += '$seq';
      i++;
    } else if (code == '%') {
      out += '%';
      i++;
    } else {
      out += '%';
    }
  }
  final trimmed = out.trim();
  return trimmed.isNotEmpty ? trimmed : '$short 第 $seq 讲';
}

String validateLessonTitleTemplate(String template) =>
    template.length > 40 ? '课时命名模板最多 40 个字' : '';
