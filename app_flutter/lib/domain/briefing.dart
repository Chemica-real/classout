// 每日简报正文 —— 从 domain/Briefing.ets 移植。判据：shared/fixtures/briefing.json。
//
// ⚠️ 「考试不算今天截止」：考试的 ddl 存的是开始时刻，再报一次"截止"只会误导。

import '../model/types.dart';
import 'dates.dart';

String buildBriefing(String dateStr, List<CourseSession> sessions, List<Todo> todos) {
  var text = '';
  if (sessions.isEmpty) {
    text = '今天没有课。';
  } else {
    final parts = <String>[];
    for (final s in sessions) {
      final name = s.course.shortName.isNotEmpty ? s.course.shortName : s.course.name;
      final loc = s.location.isNotEmpty ? ' ${s.location}' : '';
      parts.add('${minToHHmm(s.startMin)} $name$loc');
    }
    text = '${sessions.length} 节课：${parts.join('；')}';
  }

  final dueToday = <String>[];
  for (final t in todos) {
    if (t.category == TodoCategory.exam) continue;
    if (t.ddl.length >= 10 && t.ddl.substring(0, 10) == dateStr) {
      final hhmm = t.ddl.length >= 16 ? t.ddl.substring(11, 16) : '';
      dueToday.add('${t.title} $hhmm');
    }
  }
  if (dueToday.isNotEmpty) {
    text += ' ｜ 今天截止：${dueToday.join('、')}';
  }
  return text;
}
