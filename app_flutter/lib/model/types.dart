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
