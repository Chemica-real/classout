// 与鸿蒙端 entry/src/main/ets/model/Types.ets 对齐的最小模型子集。
// 字段名用 camelCase（和备份 JSON 一致，见 shared/backup-v1.md）。

class TodoStatus {
  static const String pending = 'pending';
  static const String active = 'active';
  static const String done = 'done';
  static const String archived = 'archived';
}

class TodoCategory {
  static const String homework = 'homework';
  static const String self = 'self';
  static const String exam = 'exam';
  /// 「无」= 没有类型
  static const String none = 'none';
  /// 已退役，只为兼容存量数据；不要再往新数据里写
  static const String other = 'other';
}

class Todo {
  int id;
  String title;
  int courseId;
  String category;
  String status;
  int priority;
  String ddl;
  String endAt;
  int estimateMin;
  String note;
  String source;
  String generationKey;
  String submitChannel;
  String repeatRule;
  String photos;
  int createdAt;
  int confirmedAt;
  int doneAt;

  Todo({
    this.id = 0,
    this.title = '',
    this.courseId = 0,
    this.category = TodoCategory.none,
    this.status = TodoStatus.active,
    this.priority = 0,
    this.ddl = '',
    this.endAt = '',
    this.estimateMin = 60,
    this.note = '',
    this.source = 'manual',
    this.generationKey = '',
    this.submitChannel = '',
    this.repeatRule = '',
    this.photos = '',
    this.createdAt = 0,
    this.confirmedAt = 0,
    this.doneAt = 0,
  });

  factory Todo.fromJson(Map<String, dynamic> j) => Todo(
        id: _int(j['id']),
        title: _str(j['title']),
        courseId: _int(j['courseId']),
        category: _strOr(j['category'], TodoCategory.none),
        status: _strOr(j['status'], TodoStatus.active),
        priority: _int(j['priority']),
        ddl: _str(j['ddl']),
        endAt: _str(j['endAt']),
        estimateMin: _int(j['estimateMin'], 60),
        note: _str(j['note']),
        source: _strOr(j['source'], 'manual'),
        generationKey: _str(j['generationKey']),
        submitChannel: _str(j['submitChannel']),
        repeatRule: _str(j['repeatRule']),
        photos: _str(j['photos']),
        createdAt: _int(j['createdAt']),
        confirmedAt: _int(j['confirmedAt']),
        doneAt: _int(j['doneAt']),
      );
}

/// 只要「待办 id + 起止分钟」的窄接口（validate.totalBlockMinutes 用，
/// 免得把那个纯函数绑死在完整的 PlanBlock 上）
abstract class PlanBlockLike {
  int get todoId;
  int get startMin;
  int get endMin;
}

class PlanBlock implements PlanBlockLike {
  int id;
  @override
  int todoId;
  int lessonId;
  String date;
  @override
  int startMin;
  @override
  int endMin;
  bool done;

  PlanBlock({
    this.id = 0,
    this.todoId = 0,
    this.lessonId = 0,
    this.date = '',
    this.startMin = 0,
    this.endMin = 0,
    this.done = false,
  });

  factory PlanBlock.fromJson(Map<String, dynamic> j) => PlanBlock(
        id: _int(j['id']),
        todoId: _int(j['todoId']),
        lessonId: _int(j['lessonId']),
        date: _str(j['date']),
        startMin: _int(j['startMin']),
        endMin: _int(j['endMin']),
        done: j['done'] == true || _int(j['done']) != 0,
      );
}

int _int(Object? v, [int fallback = 0]) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

String _strOr(Object? v, String fallback) =>
    (v is String && v.isNotEmpty) ? v : fallback;

// ---------------- 课表相关的模型 ----------------

class OverrideKind {
  static const String cancel = 'cancel';
  static const String move = 'move';
  static const String room = 'room';
  static const String extra = 'extra';
}

class Semester {
  int id;
  String name;
  String startDate; // 'YYYY-MM-DD'
  int totalWeeks;
  int firstDayOfWeek;
  bool showWeekend;

  Semester({
    this.id = 0,
    this.name = '',
    this.startDate = '',
    this.totalWeeks = 16,
    this.firstDayOfWeek = 1,
    this.showWeekend = true,
  });

  factory Semester.fromJson(Map<String, dynamic> j) => Semester(
        id: _int(j['id']),
        name: _str(j['name']),
        startDate: _str(j['startDate']),
        totalWeeks: _int(j['totalWeeks'], 16),
        firstDayOfWeek: _int(j['firstDayOfWeek'], 1),
        showWeekend: j['showWeekend'] != false && _int(j['showWeekend'], 1) != 0,
      );
}

class Course {
  int id;
  int semesterId;
  String name;
  String shortName;
  String teacher;
  String location;
  int colorIndex;
  bool autoTodoEnabled;
  bool isVirtual;
  String note;

  Course({
    this.id = 0,
    this.semesterId = 0,
    this.name = '',
    this.shortName = '',
    this.teacher = '',
    this.location = '',
    this.colorIndex = 0,
    this.autoTodoEnabled = true,
    this.isVirtual = false,
    this.note = '',
  });

  factory Course.fromJson(Map<String, dynamic> j) => Course(
        id: _int(j['id']),
        semesterId: _int(j['semesterId']),
        name: _str(j['name']),
        shortName: _strOr(j['shortName'], _str(j['name'])),
        teacher: _str(j['teacher']),
        location: _str(j['location']),
        colorIndex: _int(j['colorIndex']),
        autoTodoEnabled: _int(j['autoTodoEnabled'], 1) != 0,
        isVirtual: _int(j['isVirtual']) != 0,
        note: _str(j['note']),
      );

  /// 课表格子上显示的短名：没填就退回全名的前 4 个字
  String get label =>
      shortName.isNotEmpty ? shortName : (name.length > 4 ? name.substring(0, 4) : name);
}

class SectionTime {
  int semesterId;
  int section;
  int startMin;
  int endMin;
  bool flexible;

  SectionTime({
    this.semesterId = 0,
    this.section = 0,
    this.startMin = 0,
    this.endMin = 0,
    this.flexible = false,
  });

  factory SectionTime.fromJson(Map<String, dynamic> j) => SectionTime(
        semesterId: _int(j['semesterId']),
        section: _int(j['section']),
        startMin: _int(j['startMin']),
        endMin: _int(j['endMin']),
        flexible: _int(j['flexible']) != 0,
      );
}

class SessionRule {
  int id;
  int courseId;
  int weekday; // 1=周一 … 7=周日
  int startSection;
  int endSection;
  String weeksMask; // '0'/'1' 组成的字符串，第 1 个字符 = 第 1 周
  String location;
  bool isQuiz;

  SessionRule({
    this.id = 0,
    this.courseId = 0,
    this.weekday = 1,
    this.startSection = 1,
    this.endSection = 2,
    this.weeksMask = '',
    this.location = '',
    this.isQuiz = false,
  });

  factory SessionRule.fromJson(Map<String, dynamic> j) => SessionRule(
        id: _int(j['id']),
        courseId: _int(j['courseId']),
        weekday: _int(j['weekday'], 1),
        startSection: _int(j['startSection'], 1),
        endSection: _int(j['endSection'], 2),
        weeksMask: _str(j['weeksMask']),
        location: _str(j['location']),
        isQuiz: _int(j['isQuiz']) != 0,
      );
}

class SessionOverride {
  int id;
  int courseId;
  String date;
  String kind;
  String newDate;
  int newStartSection;
  int newEndSection;
  String newLocation;

  SessionOverride({
    this.id = 0,
    this.courseId = 0,
    this.date = '',
    this.kind = '',
    this.newDate = '',
    this.newStartSection = 0,
    this.newEndSection = 0,
    this.newLocation = '',
  });

  factory SessionOverride.fromJson(Map<String, dynamic> j) => SessionOverride(
        id: _int(j['id']),
        courseId: _int(j['courseId']),
        date: _str(j['date']),
        kind: _str(j['kind']),
        newDate: _str(j['newDate']),
        newStartSection: _int(j['newStartSection']),
        newEndSection: _int(j['newEndSection']),
        newLocation: _str(j['newLocation']),
      );
}

/// 算出来的一节课（规则课 or 补课），课表格子直接画它
class CourseSession {
  final Course course;
  final SessionRule rule;
  final String date;
  final String originDate;
  final int weekday;
  final int startSection;
  final int endSection;
  final int startMin;
  final int endMin;
  final String location;
  final bool isQuiz;
  final bool fromOverride;
  final bool isExtra;

  const CourseSession({
    required this.course,
    required this.rule,
    required this.date,
    required this.originDate,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.startMin,
    required this.endMin,
    required this.location,
    required this.isQuiz,
    required this.fromOverride,
    required this.isExtra,
  });
}


/// 不可排时段（午休/晚饭/睡觉…）；weekday 0 = 每天，1..7 = 周一..周日
class RestWindow {
  int id;
  int weekday;
  int startMin;
  int endMin;
  String label;

  RestWindow({
    this.id = 0,
    this.weekday = 0,
    this.startMin = 0,
    this.endMin = 0,
    this.label = '',
  });

  factory RestWindow.fromJson(Map<String, dynamic> j) => RestWindow(
        id: _int(j['id']),
        weekday: _int(j['weekday']),
        startMin: _int(j['startMin']),
        endMin: _int(j['endMin']),
        label: _str(j['label']),
      );
}
