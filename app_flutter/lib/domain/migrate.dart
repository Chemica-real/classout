// 老数据的迁移 —— 鸿蒙端 `data/Seeder.ets → migrateData()` 的安卓版：
//
//   ① `TodoRepo.normalizeAllEstimates`：待办时长按 5 分钟分度重算；
//      考试恒为 0；非正数按 60；下限 15（**不设上限**，那是 migrateEstimate 与 normalize 的区别）。
//   ② `TodoRepo.migrateCategories`：退役的 `'other'`（「其他」）→ `'none'`（「无」），
//      待办表与模板表都改。
//
// 鸿蒙是每次启动都跑一遍（幂等：返回改了几条）。安卓的旧版本/导入的备份里也可能带这些值，
// 所以同样在冷启动读库之后跑一次，改到了就整份写回。
//
// 纯函数、无副作用，返回 `null` 表示"没有需要改的"。

import '../data/backup.dart';
import '../model/types.dart';
import 'categories.dart' show legacyOther;
import 'validate.dart';

/// 迁移一份数据。没有改动时返回 null（调用方据此决定要不要写库）。
BackupBundle? migrateBundle(BackupBundle b) {
  var changes = 0;

  final todos = <Todo>[];
  for (final t in b.todos) {
    final want =
        migrateEstimate(t.estimateMin, t.category == TodoCategory.exam);
    final cat = t.category == legacyOther ? TodoCategory.none : t.category;
    if (want == t.estimateMin && cat == t.category) {
      todos.add(t);
      continue;
    }
    changes++;
    todos.add(t.copyWith(estimateMin: want, category: cat));
  }

  final templates = <TodoTemplate>[];
  for (final t in b.templates) {
    if (t.category != legacyOther) {
      templates.add(t);
      continue;
    }
    changes++;
    templates.add(t.copyWith(category: TodoCategory.none));
  }

  if (changes == 0) return null;
  return b.copyWith(todos: todos, templates: templates);
}
