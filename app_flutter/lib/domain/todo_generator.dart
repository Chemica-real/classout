// 下课自动生成待办 —— 鸿蒙端 `domain/TodoGenerator.ets` 的纯逻辑版。
//
// 鸿蒙端的实现直接读库（TemplateRepo/TodoRepo），Dart 这边拆成两层：
//   · 纯函数：renderTitle / computeDdl / nextSessionOfCourse / generateMissedTodos
//     （给定 bundle + kv 里的 last_gen_date，返回"要新建哪些待办"+ 新的 last_gen_date）
//   · 调用层：HomeShell 读 kv → 调这里 → 把新待办塞回 bundle 写库 → 写回 kv
//
// 与鸿蒙端逐条一致的点：
//   · 只有 `course.autoTodoEnabled` 的课才生成；
//   · 去重键 `courseId|date|templateId`（generationKey），重复触发不生成第二份；
//   · 「已经下课」才生成（当天要 endMin <= 现在分钟）；
//   · 备注**不**从模板带过来（用户要求："自动生成的时候不可以自动生成备注"）；
//   · 状态是 pending（待确认），source = template；
//   · `%N` 是"这门课第几次作业" = 已有该课程模板待办数 + 1。

import '../model/types.dart';
import 'dates.dart';
import 'js_compat.dart';
import 'timetable.dart';

/// next_session 向前找多少天（鸿蒙端 LOOKAHEAD_DAYS）
const int lookaheadDays = 28;

/// 模板变量替换
///   %C 课程全名   %c 简称     %D 布置日期(M.D)   %d 布置日期(YYYY-MM-DD)
///   %W 第几周     %T 起始节次  %N 第 N 次作业     %R 教室
String renderTitle(String tpl, CourseSession s, int week, int n) {
  final short = s.course.shortName.isNotEmpty ? s.course.shortName : s.course.name;
  return tpl
      .replaceAll('%C', s.course.name)
      .replaceAll('%c', short)
      .replaceAll('%D', monthDayText(parseDate(s.date)))
      .replaceAll('%d', s.date)
      .replaceAll('%W', '$week')
      .replaceAll('%T', '${s.startSection}')
      .replaceAll('%N', '$n')
      .replaceAll('%R', s.location);
}

/// 某一天的全部课时（= computeWeekSessions 里那一天的那些）
List<CourseSession> sessionsOnDate(
  Semester sem,
  List<Course> courses,
  List<SessionRule> rules,
  List<SessionOverride> overrides,
  List<SectionTime> times,
  DateTime d,
) {
  final week = weekOfDate(sem, d);
  if (week < 1 || week > sem.totalWeeks) return const [];
  final key = formatDate(d);
  return computeWeekSessions(sem, courses, rules, overrides, times, week)
      .where((s) => s.date == key)
      .toList();
}

/// 找某门课在 afterDate 之后（不含当天）的第一节课
CourseSession? nextSessionOfCourse(
  Semester sem,
  List<Course> courses,
  List<SessionRule> rules,
  List<SessionOverride> overrides,
  List<SectionTime> times,
  int courseId,
  DateTime afterDate,
) {
  for (var i = 1; i <= lookaheadDays; i++) {
    final d = addDays(afterDate, i);
    for (final s in sessionsOnDate(sem, courses, rules, overrides, times, d)) {
      if (s.course.id == courseId) return s;
    }
  }
  return null;
}

/// 计算截止时间字符串 'YYYY-MM-DD HH:mm'
///   none          不设截止
///   same_day      当天 23:59
///   days:N        N 天后 23:59
///   weekday:N     最近（含当天）的星期 N 23:59
///   week_end      本周日 23:59
///   next_session  下一次同门课当天 23:59
String computeDdl(
  Semester sem,
  List<Course> courses,
  List<SessionRule> rules,
  List<SessionOverride> overrides,
  List<SectionTime> times,
  CourseSession s,
  String ddlRule,
  String ddlParam,
) {
  final base = parseDate(s.date);
  switch (ddlRule) {
    case 'none':
      return '';
    case 'same_day':
      return '${s.date} 23:59';
    case 'days':
      final step = jsParseInt(ddlParam) ?? 1;
      return '${formatDate(addDays(base, step))} 23:59';
    case 'weekday':
      final want = jsParseInt(ddlParam) ?? 7;
      final delta = (want - weekdayOf(base) + 7) % 7;
      return '${formatDate(addDays(base, delta))} 23:59';
    case 'week_end':
      final delta = 7 - weekdayOf(base);
      return '${formatDate(addDays(base, delta))} 23:59';
    case 'next_session':
      final next = nextSessionOfCourse(
          sem, courses, rules, overrides, times, s.course.id, base);
      final d = next == null ? addDays(base, 7) : parseDate(next.date);
      return '${formatDate(d)} 23:59';
    default:
      return '';
  }
}

/// 一次补生成的结果
class GenerationOutcome {
  /// 新建的待办（id 已经由调用方分配好）
  final List<Todo> created;
  /// 扫描了多少天
  final int scannedDays;
  /// 应该写回 kv `last_gen_date` 的值
  final String lastGenDate;

  const GenerationOutcome(this.created, this.scannedDays, this.lastGenDate);
}

String templateKey(int courseId, String date, int templateId) =>
    '$courseId|$date|$templateId';

/// 静默补生成：把 [lastGenDate]（含）到今天之间**已经下课**的课时生成成待办。
///
/// [now] 可注入（测试不能依赖真实时钟）；[nextId] 用来给新待办编号。
GenerationOutcome generateMissedTodos({
  required Semester sem,
  required List<Course> courses,
  required List<SessionRule> rules,
  required List<SessionOverride> overrides,
  required List<SectionTime> times,
  required List<TodoTemplate> templates,
  required List<Todo> todos,
  required String lastGenDate,
  required DateTime now,
  int nextId = 0,
  /// 黑名单（鸿蒙 `todo_blacklist` 表）：用户删掉过的自动生成待办，不再重新生成
  Set<String> blacklist = const <String>{},
}) {
  final endDate = DateTime(now.year, now.month, now.day);
  var startDate = endDate;
  if (lastGenDate.isNotEmpty) {
    final parsed = parseDate(lastGenDate);
    if (parsed.isBefore(endDate)) startDate = parsed;
  }
  final nowMin = now.hour * 60 + now.minute;
  final todayKey = formatDate(endDate);
  final keys = {for (final t in todos) t.generationKey};
  final out = <Todo>[];
  var scanned = 0;
  var id = nextId;

  final totalDays = diffDays(endDate, startDate);
  for (var offset = 0; offset <= totalDays; offset++) {
    final d = addDays(startDate, offset);
    scanned++;
    final dayKey = formatDate(d);
    final isToday = dayKey == todayKey;
    final sessions =
        sessionsOnDate(sem, courses, rules, overrides, times, d);
    for (final s in sessions) {
      if (!s.course.autoTodoEnabled) continue;
      // 还没下课就跳过（鸿蒙端：当天 endMin > nowMin 跳过）
      if (isToday && s.endMin > nowMin) continue;
      for (final t in templates) {
        if (t.courseId != s.course.id || !t.enabled) continue;
        final key = templateKey(s.course.id, s.date, t.id);
        if (keys.contains(key)) continue;
        // 被删过的（进了黑名单）不再生成 —— 鸿蒙 `isBlacklisted` 同款
        if (blacklist.contains(key)) continue;
        final n = todos.where((x) => x.courseId == s.course.id).length + 1;
        final week = weekOfDate(sem, parseDate(s.date));
        id++;
        out.add(Todo(
          id: id,
          title: renderTitle(t.titleTemplate, s, week, n),
          courseId: s.course.id,
          category: t.category,
          priority: 1,
          ddl: computeDdl(sem, courses, rules, overrides, times, s, t.ddlRule,
              t.ddlParam),
          endAt: '',
          estimateMin: t.estimateMin,
          status: TodoStatus.pending,
          source: 'template',
          generationKey: key,
          // 备注不从模板带（用户明确要求）
          note: '',
          submitChannel: t.submitChannel,
          repeatRule: '',
          photos: '',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          confirmedAt: 0,
          doneAt: 0,
        ));
        keys.add(key);
      }
    }
  }
  return GenerationOutcome(out, scanned, todayKey);
}

/// 虚拟课程的某一讲完成 → 跟真课下课一样，按课程模板生成待办。
///
/// 对应鸿蒙端 `generateForLesson`：用课时计划的日期/起止分钟伪造一个 `CourseSession`
/// （虚拟课程本来就没有节次规则），再走与真课完全相同的那套规则：
/// 只在 `autoTodoEnabled` 时生成、去重键 `course|date|template`、备注为空、状态 pending。
GenerationOutcome generateForLesson({
  required List<Course> courses,
  required List<SessionRule> rules,
  required List<SectionTime> times,
  required List<TodoTemplate> templates,
  required List<Todo> todos,
  required Semester sem,
  required VirtualLesson lesson,
  required String date,
  required int startMin,
  required int endMin,
  int nextId = 0,
  Set<String> blacklist = const <String>{},
}) {
  Course? course;
  for (final c in courses) {
    if (c.id == lesson.courseId) course = c;
  }
  if (course == null) return GenerationOutcome(const [], 0, '');
  final s = lessonSessionFor(course, date, startMin, endMin);
  final planned = planSessionTodos(
    sem: sem,
    courses: courses,
    rules: rules,
    times: times,
    templates: templates,
    s: s,
    existingKeys: [for (final t in todos) t.generationKey],
    existingForCourse: todos.where((x) => x.courseId == course!.id).length,
  );
  final out = <Todo>[];
  var id = nextId;
  for (final p in planned) {
    // 黑名单里的不再生成（鸿蒙 `generateForSession` 里逐条 `isBlacklisted`）
    if (blacklist.contains(p.key)) continue;
    id++;
    out.add(Todo(
      id: id,
      title: p.title,
      courseId: course.id,
      category: p.category,
      priority: 1,
      ddl: p.ddl,
      endAt: '',
      estimateMin: p.estimateMin,
      status: TodoStatus.pending,
      source: 'template',
      generationKey: p.key,
      note: '',
      submitChannel: p.submitChannel,
      repeatRule: '',
      photos: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      confirmedAt: 0,
      doneAt: 0,
    ));
  }
  return GenerationOutcome(out, 1, date);
}

/// 虚拟课程的"合成课时"（对应 ArkTS `lessonSessionFor`）：用计划块的日期与起止分钟
/// 伪造一个 `CourseSession`，后面的规则就能和真课完全一样。
CourseSession lessonSessionFor(Course course, String date, int startMin, int endMin,
        {String location = ''}) =>
    CourseSession(
      course: course,
      rule: SessionRule(
        id: 0,
        courseId: course.id,
        weekday: 0,
        startSection: 0,
        endSection: 0,
        weeksMask: '',
        location: location,
        isQuiz: false,
      ),
      date: date,
      originDate: date,
      weekday: weekdayOf(parseDate(date)),
      startSection: 0,
      endSection: 0,
      startMin: startMin,
      endMin: endMin,
      location: location.isNotEmpty ? location : course.location,
      isQuiz: false,
      fromOverride: false,
      isExtra: false,
    );

/// 一条"该生成什么"的计划（对应 ArkTS `PlannedGen`）
class PlannedGen {
  final String key;
  final String title;
  final String ddl;
  final int estimateMin;
  final String category;
  final String submitChannel;
  const PlannedGen(this.key, this.title, this.ddl, this.estimateMin,
      this.category, this.submitChannel);

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'ddl': ddl,
        'estimateMin': estimateMin,
        'category': category,
        'submitChannel': submitChannel,
      };
}

/// 给定一节课与这门课的模板，算出该新建哪些待办（不发通知、不写库）。
/// 与 ArkTS `planSessionTodos` 逐条一致（fixtures/todo_gen 对拍）。
List<PlannedGen> planSessionTodos({
  required Semester sem,
  required List<Course> courses,
  required List<SessionRule> rules,
  required List<SectionTime> times,
  required List<TodoTemplate> templates,
  required CourseSession s,
  required List<String> existingKeys,
  required int existingForCourse,
}) {
  final out = <PlannedGen>[];
  if (!s.course.autoTodoEnabled) return out;
  final week = weekOfDate(sem, parseDate(s.date));
  var n = existingForCourse;
  for (final t in templates) {
    if (t.courseId != s.course.id || !t.enabled) continue;
    final key = templateKey(s.course.id, s.date, t.id);
    if (existingKeys.contains(key)) continue;
    n++;
    out.add(PlannedGen(
      key,
      renderTitle(t.titleTemplate, s, week, n),
      computeDdl(sem, courses, rules, const [], times, s, t.ddlRule, t.ddlParam),
      t.estimateMin,
      t.category,
      t.submitChannel,
    ));
  }
  return out;
}
