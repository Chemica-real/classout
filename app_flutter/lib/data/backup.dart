// 备份 JSON 的解析 —— 格式规范见 shared/backup-v1.md。
//
// 这是三端之间最硬的数据通道：鸿蒙端导出 → iOS/Android 端导入，字段必须一一对上。
// 解析器**宽容**：缺字段按默认值补，不认识的字段忽略（前向兼容）。

import 'dart:convert';

import '../model/types.dart';

class BackupBundle {
  final String app;
  final int version;
  final String exportedAt;
  final List<Semester> semesters;
  final List<SectionTime> sectionTimes;
  final List<Course> courses;
  final List<SessionRule> rules;
  final List<SessionOverride> overrides;
  final List<Todo> todos;
  final List<PlanBlock> blocks;
  final List<RestWindow> restWindows;

  const BackupBundle({
    required this.app,
    required this.version,
    required this.exportedAt,
    required this.semesters,
    required this.sectionTimes,
    required this.courses,
    required this.rules,
    required this.overrides,
    required this.todos,
    required this.blocks,
    this.restWindows = const [],
  });

  /// 当前学期（暂时取第一条；以后有学期切换再说）
  Semester? get semester => semesters.isEmpty ? null : semesters.first;

  static List<T> _list<T>(Map<String, dynamic> j, String key, T Function(Map<String, dynamic>) f) =>
      (j[key] as List? ?? const [])
          .map((e) => f(Map<String, dynamic>.from(e as Map)))
          .toList();

  factory BackupBundle.fromJson(Map<String, dynamic> j) {
    final app = j['app'] as String? ?? '';
    if (app != 'ClassOUT') {
      throw FormatException('这不是 ClassOUT 的备份文件（app = "$app"）');
    }
    final version = (j['version'] as num?)?.toInt() ?? 0;
    if (version > 1) {
      throw FormatException('备份来自更新版本（version = $version），请先升级 App');
    }
    return BackupBundle(
      app: app,
      version: version,
      exportedAt: j['exportedAt'] as String? ?? '',
      semesters: _list(j, 'semesters', Semester.fromJson),
      sectionTimes: _list(j, 'sectionTimes', SectionTime.fromJson),
      courses: _list(j, 'courses', Course.fromJson),
      rules: _list(j, 'rules', SessionRule.fromJson),
      overrides: _list(j, 'overrides', SessionOverride.fromJson),
      todos: _list(j, 'todos', Todo.fromJson),
      blocks: _list(j, 'blocks', PlanBlock.fromJson),
      restWindows: _list(j, 'restWindows', RestWindow.fromJson),
    );
  }

  factory BackupBundle.decode(String source) =>
      BackupBundle.fromJson(jsonDecode(source) as Map<String, dynamic>);
}
