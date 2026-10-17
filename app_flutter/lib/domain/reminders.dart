// 提醒排期（纯逻辑）—— 从 domain/ReminderScheduler.ets 抽出「算哪些提醒、什么时候响」。
//
// ⚠️ 与鸿蒙端的关系：那边 `syncReminders()` 把「查库 + 算 + 调平台 API」写在一个函数里，
//    所以**没法直接进 fixtures**。这边把「算」单独抽成纯函数（真机难反复试的正是这一段），
//    由 `test/reminders_test.dart` 用手写断言钉住；等再动鸿蒙端时，建议也在那边把
//    `buildCandidates()` 抽出来，就能用 fixtures 对拍了（HANDOFF §41 记了这条）。
//
// 为什么是「每次全量重排」而不是增量：本地通知的**待发上限是 64 条**（iOS
// UNUserNotificationCenter；鸿蒙代理提醒也是 64）。每次启动把旧的撤掉、按当前课表
// 重排一个滚动窗口，简单且不会累积重复。

import '../model/types.dart';
import 'briefing.dart';
import 'dates.dart';
import 'timetable.dart';

/// 排期窗口（天）：上课提醒与简报
const int reminderWindowDays = 7;
/// 计划块提醒只排近几天（块是会改的）
const int blockWindowDays = 3;
/// 预算：本地通知的待发上限，留一点余量
const int reminderBudget = 60;

const int defaultBriefMin = 7 * 60 + 30;
const int defaultClassLeadMin = 15;

class ReminderSettings {
  bool briefEnabled;
  int briefMin;
  int classLeadMin;

  ReminderSettings({
    this.briefEnabled = true,
    this.briefMin = defaultBriefMin,
    this.classLeadMin = defaultClassLeadMin,
  });
}

class PlannedReminder {
  final DateTime at;
  final String title;
  final String content;
  final String kind; // class / ddl / block / brief

  const PlannedReminder(this.at, this.title, this.content, this.kind);

  @override
  String toString() => '[$kind] $at $title — $content';
}

class ReminderPlanResult {
  final List<PlannedReminder> published; // 被预算接纳的（按时间升序）
  final int skippedByBudget;
  final int classes;
  final int ddl;
  final int blocks;
  final int briefs;

  const ReminderPlanResult({
    required this.published,
    required this.skippedByBudget,
    required this.classes,
    required this.ddl,
    required this.blocks,
    required this.briefs,
  });

  int get total => published.length + skippedByBudget;
}

DateTime _atTime(DateTime day, int hour, int minute) =>
    DateTime(day.year, day.month, day.day, hour, minute);

/// ddl 'YYYY-MM-DD HH:mm' → 本地时刻；没有时刻返回 null
DateTime? ddlDateTime(String ddl) {
  if (ddl.length < 16) return null;
  return DateTime(
    int.tryParse(ddl.substring(0, 4)) ?? 1970,
    (int.tryParse(ddl.substring(5, 7)) ?? 1),
    int.tryParse(ddl.substring(8, 10)) ?? 1,
    int.tryParse(ddl.substring(11, 13)) ?? 0,
    int.tryParse(ddl.substring(14, 16)) ?? 0,
  );
}

/// 全部候选（未截断），按时间升序
List<PlannedReminder> buildReminderCandidates({
  required Semester sem,
  required List<Course> courses,
  required List<SessionRule> rules,
  required List<SectionTime> times,
  required List<SessionOverride> overrides,
  required List<Todo> todos,
  required List<PlanBlock> blocks,
  required ReminderSettings settings,
  required DateTime now,
  int windowDays = reminderWindowDays,
  int blockDays = blockWindowDays,
}) {
  final courseMap = {for (final c in courses) c.id: c};
  final out = <PlannedReminder>[];
  final todayStart = DateTime(now.year, now.month, now.day);

  // ---- 上课前提醒 + 每日简报 ----
  for (var offset = 0; offset <= windowDays; offset++) {
    final d = addDays(todayStart, offset);
    final week = weekOfDate(sem, d);
    if (week < 1 || week > sem.totalWeeks) continue;
    final dateStr = formatDate(d);
    final sessions = computeWeekSessions(sem, courses, rules, overrides, times, week);
    final daySessions = sessions.where((s) => s.date == dateStr).toList();

    for (final s in daySessions) {
      final startAt = DateTime(
          d.year, d.month, d.day, s.startMin ~/ 60, s.startMin % 60);
      final remindAt = startAt.subtract(Duration(minutes: settings.classLeadMin));
      if (!remindAt.isAfter(now)) continue;
      final name = s.course.shortName.isNotEmpty ? s.course.shortName : s.course.name;
      final loc = s.location.isNotEmpty ? s.location : '教室待定';
      final teacher = s.course.teacher.isNotEmpty ? ' · ${s.course.teacher}' : '';
      out.add(PlannedReminder(remindAt, '$name 还有 ${settings.classLeadMin} 分钟上课',
          '$loc$teacher', 'class'));
    }

    if (settings.briefEnabled) {
      final briefAt =
          _atTime(d, settings.briefMin ~/ 60, settings.briefMin % 60);
      if (briefAt.isAfter(now)) {
        out.add(PlannedReminder(briefAt, '今日简报',
            buildBriefing(dateStr, daySessions, todos), 'brief'));
      }
    }
  }

  // ---- 作业截止：前一天 20:00；已过则退化为截止前 2 小时 ----
  for (final t in todos) {
    // ⚠️ **考试不排「即将截止」**。考试的 ddl 存的是它的**开始时刻**，
    //    排成"XX 即将截止"语义就错了（用户 2026-10-16：「考试无需显示截止」）。
    //    鸿蒙端 `ReminderScheduler.syncReminders()` 里**漏了这一条**（见 HANDOFF §41），
    //    所以这边是有意与它不一致的修正 —— 考试的提醒交给它的计划块（到点提醒）。
    if (t.category == TodoCategory.exam) continue;
    final due = ddlDateTime(t.ddl);
    if (due == null || !due.isAfter(now)) continue;
    var at = _atTime(addDays(due, -1), 20, 0);
    if (!at.isAfter(now)) at = due.subtract(const Duration(hours: 2));
    if (!at.isAfter(now)) continue;
    if (at.difference(now).inMilliseconds > windowDays * 86400000) continue;
    final course = courseMap[t.courseId];
    out.add(PlannedReminder(at, '${t.title} 即将截止',
        '截止 ${t.ddl}${course == null ? '' : ' · ${course.name}'}', 'ddl'));
  }

  // ---- 计划块到点 ----
  for (var offset = 0; offset <= blockDays; offset++) {
    final d = addDays(todayStart, offset);
    final dateStr = formatDate(d);
    for (final b in blocks) {
      if (b.date != dateStr || b.done) continue;
      final at = DateTime(d.year, d.month, d.day, b.startMin ~/ 60, b.startMin % 60);
      if (!at.isAfter(now)) continue;
      var title = '该做这件事了';
      for (final t in todos) {
        if (t.id == b.todoId) title = '该做「${t.title}」了';
      }
      out.add(PlannedReminder(
          at, title, '计划 ${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}', 'block'));
    }
  }

  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// 排期 + 预算截断（早的先保，超出的计入 skippedByBudget）
ReminderPlanResult planReminders({
  required Semester sem,
  required List<Course> courses,
  required List<SessionRule> rules,
  required List<SectionTime> times,
  required List<SessionOverride> overrides,
  required List<Todo> todos,
  required List<PlanBlock> blocks,
  required ReminderSettings settings,
  required DateTime now,
  int windowDays = reminderWindowDays,
  int blockDays = blockWindowDays,
  int budget = reminderBudget,
}) {
  final all = buildReminderCandidates(
    sem: sem,
    courses: courses,
    rules: rules,
    times: times,
    overrides: overrides,
    todos: todos,
    blocks: blocks,
    settings: settings,
    now: now,
    windowDays: windowDays,
    blockDays: blockDays,
  );
  final published = all.take(budget).toList();
  return ReminderPlanResult(
    published: published,
    skippedByBudget: all.length - published.length,
    classes: all.where((r) => r.kind == 'class').length,
    ddl: all.where((r) => r.kind == 'ddl').length,
    blocks: all.where((r) => r.kind == 'block').length,
    briefs: all.where((r) => r.kind == 'brief').length,
  );
}
