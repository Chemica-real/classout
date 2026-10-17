// SQLite 实现：库表结构完全照 ../shared/schema.sql（assets/schema.sql 是它的副本，
// db_test 会校验两份一字不差，防止漂移）。

import 'package:sqlite3/sqlite3.dart';

import '../model/types.dart';
import 'backup.dart';
import 'repo.dart';
import 'sqlite_open.dart';

class SqliteRepo implements ClassOutRepo {
  final Database db;

  SqliteRepo._(this.db);

  /// 用 schema.sql 建库（内存或文件）
  factory SqliteRepo.withSchema({String? path, required String schemaSql}) {
    final raw = path == null ? openMemoryDatabase() : openFileDatabase(path);
    for (final stmt in splitSchema(schemaSql)) {
      raw.execute(stmt);
    }
    return SqliteRepo._(raw);
  }

  @override
  Future<BackupBundle?> load() async {
    if (_count('semester') == 0) return null;
    return BackupBundle(
      app: 'ClassOUT',
      version: 1,
      exportedAt: '',
      semesters: _rows('semester').map(Semester.fromJson).toList(),
      sectionTimes: _rows('section_time').map(SectionTime.fromJson).toList(),
      courses: _rows('course').map(Course.fromJson).toList(),
      rules: _rows('session_rule').map(SessionRule.fromJson).toList(),
      overrides:
          _rows('session_override').map(SessionOverride.fromJson).toList(),
      todos: _rows('todo').map(Todo.fromJson).toList(),
      blocks: _rows('plan_block').map(PlanBlock.fromJson).toList(),
      restWindows: _rows('rest_window').map(RestWindow.fromJson).toList(),
      templates: _rows('todo_template').map(TodoTemplate.fromJson).toList(),
    );
  }

  @override
  Future<void> replaceAll(BackupBundle b) async {
    db.execute('BEGIN');
    try {
      for (final t in _tableOrder) {
        db.execute('DELETE FROM $t');
      }
      for (final s in b.semesters) {
        _insert('semester', {
          'id': s.id,
          'name': s.name,
          'start_date': s.startDate,
          'total_weeks': s.totalWeeks,
          'first_day_of_week': s.firstDayOfWeek,
          'show_weekend': s.showWeekend ? 1 : 0,
        });
      }
      for (final t in b.sectionTimes) {
        _insert('section_time', {
          'semester_id': t.semesterId,
          'section': t.section,
          'start_min': t.startMin,
          'end_min': t.endMin,
          'flexible': t.flexible ? 1 : 0,
        });
      }
      for (final c in b.courses) {
        _insert('course', {
          'id': c.id,
          'semester_id': c.semesterId,
          'name': c.name,
          'short_name': c.shortName,
          'teacher': c.teacher,
          'location': c.location,
          'color_index': c.colorIndex,
          'auto_todo_enabled': c.autoTodoEnabled ? 1 : 0,
          'is_virtual': c.isVirtual ? 1 : 0,
          'note': c.note,
        });
      }
      for (final r in b.rules) {
        _insert('session_rule', {
          'id': r.id,
          'course_id': r.courseId,
          'weekday': r.weekday,
          'start_section': r.startSection,
          'end_section': r.endSection,
          'weeks_mask': r.weeksMask,
          'location': r.location,
          'is_quiz': r.isQuiz ? 1 : 0,
        });
      }
      for (final o in b.overrides) {
        _insert('session_override', {
          'id': o.id,
          'course_id': o.courseId,
          'date': o.date,
          'kind': o.kind,
          'new_date': o.newDate,
          'new_start_section': o.newStartSection,
          'new_end_section': o.newEndSection,
          'new_location': o.newLocation,
        });
      }
      for (final t in b.todos) {
        _insert('todo', {
          'id': t.id,
          'title': t.title,
          'course_id': t.courseId,
          'category': t.category,
          'priority': t.priority,
          'ddl': t.ddl,
          'end_at': t.endAt,
          'estimate_min': t.estimateMin,
          'status': t.status,
          'source': t.source,
          'generation_key': t.generationKey,
          'note': t.note,
          'submit_channel': t.submitChannel,
          'repeat_rule': t.repeatRule,
          'photos': t.photos,
          'created_at': t.createdAt,
          'confirmed_at': t.confirmedAt,
          'done_at': t.doneAt,
        });
      }
      for (final t in b.templates) {
        _insert('todo_template', {
          if (t.id > 0) 'id': t.id,
          'course_id': t.courseId,
          'sort_order': t.sortOrder,
          'enabled': t.enabled ? 1 : 0,
          'title_template': t.titleTemplate,
          'ddl_rule': t.ddlRule,
          'ddl_param': t.ddlParam,
          'estimate_min': t.estimateMin,
          'category': t.category,
          'submit_channel': t.submitChannel,
          'note': t.note,
        });
      }
      for (final r in b.restWindows) {
        // ⚠️ id = 0 表示"还没入库"，必须让 AUTOINCREMENT 自己分配 ——
        //    显式写 0 会让第二行撞 UNIQUE(id)。鸿蒙端也只存 start/end/label。
        _insert('rest_window', {
          if (r.id > 0) 'id': r.id,
          'weekday': r.weekday,
          'start_min': r.startMin,
          'end_min': r.endMin,
          'label': r.label,
        });
      }
      for (final p in b.blocks) {
        _insert('plan_block', {
          'id': p.id,
          'todo_id': p.todoId,
          'lesson_id': p.lessonId,
          'date': p.date,
          'start_min': p.startMin,
          'end_min': p.endMin,
          'done': p.done ? 1 : 0,
        });
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> close() async => db.dispose();

  @override
  Future<String?> getKv(String key) async {
    final rs = db.select('SELECT v FROM kv WHERE k = ?', [key]);
    return rs.isEmpty ? null : rs.first['v'] as String;
  }

  @override
  Future<void> setKv(String key, String value) async {
    db.execute('INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)', [key, value]);
  }

  // ---------------- 内部 ----------------

  /// 清库顺序无所谓（schema 没建外键约束），但读的顺序要稳定
  static const List<String> _tableOrder = [
    'plan_block',
    'todo',
    'session_override',
    'session_rule',
    'course',
    'section_time',
    'semester',
    'rest_window',
    'todo_template',
  ];

  int _count(String table) =>
      (db.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int);

  /// 读出来的列名是 snake_case，模型要的是 camelCase —— 必须转，否则
  /// courseId/ddl 这类字段会静默变成 0 / 空串（课表直接错乱）。
  List<Map<String, dynamic>> _rows(String table) => db
      .select('SELECT * FROM $table')
      .map((r) => {
            for (final e in Map<String, dynamic>.from(r).entries)
              _camel(e.key): e.value,
          })
      .toList();

  void _insert(String table, Map<String, dynamic> values) {
    final cols = values.keys.join(', ');
    final marks = List<String>.filled(values.length, '?').join(', ');
    db.execute(
        'INSERT INTO $table ($cols) VALUES ($marks)', values.values.toList());
  }
}

/// 'new_start_section' → 'newStartSection'
String _camel(String snake) {
  final parts = snake.split('_');
  final buf = StringBuffer(parts.first);
  for (final p in parts.skip(1)) {
    if (p.isEmpty) continue;
    buf.write(p[0].toUpperCase());
    buf.write(p.substring(1));
  }
  return buf.toString();
}
