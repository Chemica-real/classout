// 老数据迁移（鸿蒙 `Seeder.migrateData`）的测试：时长归一化 + 「其他」退役。

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/domain/migrate.dart';
import 'package:classout/model/types.dart';

BackupBundle _bundle({List<Todo>? todos, List<TodoTemplate>? templates}) =>
    BackupBundle(
      app: 'ClassOUT',
      version: 1,
      exportedAt: '',
      semesters: const [],
      sectionTimes: const [],
      courses: const [],
      rules: const [],
      overrides: const [],
      todos: todos ?? const [],
      blocks: const [],
      restWindows: const [],
      templates: templates ?? const [],
      lessons: const [],
    );

void main() {
  test('时长：17 → 15、3 → 15、0 → 60、考试一律 0（不设上限）', () {
    final b = _bundle(todos: [
      Todo(id: 1, estimateMin: 17),
      Todo(id: 2, estimateMin: 3),
      Todo(id: 3, estimateMin: 0),
      Todo(id: 4, estimateMin: 690),
      Todo(id: 5, estimateMin: 45, category: TodoCategory.exam),
    ]);
    final m = migrateBundle(b)!;
    expect(m.todos.map((t) => t.estimateMin).toList(), [15, 15, 60, 690, 0]);
  });

  test('「其他」退役：待办与模板都改成「无」', () {
    final b = _bundle(
      todos: [Todo(id: 1, estimateMin: 60, category: 'other')],
      templates: [TodoTemplate(id: 1, category: 'other')],
    );
    final m = migrateBundle(b)!;
    expect(m.todos.single.category, TodoCategory.none);
    expect(m.templates.single.category, TodoCategory.none);
  });

  test('幂等：没有要改的就返回 null', () {
    final b = _bundle(todos: [Todo(id: 1, estimateMin: 30)]);
    expect(migrateBundle(b), isNull);
  });
}
