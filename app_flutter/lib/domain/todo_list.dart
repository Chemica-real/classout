// 待办列表的规则：四段分组、两种排序、三种文案。
//
// 与鸿蒙端的对应关系：
//  - 分组：`view/TodoInbox.ets` 的四段（待确认 / 即将考试 / 待办 / 已完成），
//    数据来自三条 SQL（pending / active / done）；
//  - 排序：`data/TodoRepo.listTodos` 的 ORDER BY（无截止的最后、ddl 升序、
//    priority 降序、id 降序）与 `listDoneTodos` 的（done_at 降序、id 降序）；
//    Dart 这边是**纯比较器**，`db_test` 里直接拿 SQLite 的 ORDER BY 对拍；
//  - 文案：`ddlText` / `examDdlText` / `doneAtText` 原本写在视图里（视图不进离线断言），
//    这里搬成纯函数，由 `todo_list_test.dart` 钉住（含"时间待定""无截止"这些边界）。

import '../model/types.dart';
import 'dates.dart';

class TodoSections {
  final List<Todo> pending; // 待确认
  final List<Todo> exams; // 即将考试（active 且 category == exam）
  final List<Todo> tasks; // 待办（active 且不是考试）
  final List<Todo> done; // 已完成

  const TodoSections(this.pending, this.exams, this.tasks, this.done);

  bool get isEmpty =>
      pending.isEmpty && exams.isEmpty && tasks.isEmpty && done.isEmpty;
}

/// 把全量待办切成四段（各自排好序）
TodoSections splitTodos(List<Todo> todos) {
  final pending = <Todo>[];
  final exams = <Todo>[];
  final tasks = <Todo>[];
  final done = <Todo>[];
  for (final t in todos) {
    switch (t.status) {
      case TodoStatus.pending:
        pending.add(t);
      case TodoStatus.active:
        (t.category == TodoCategory.exam ? exams : tasks).add(t);
      case TodoStatus.done:
        done.add(t);
      case TodoStatus.archived:
        done.add(t); // 已归档也归到"已完成"那一块（加灰显示）
      default:
        tasks.add(t);
    }
  }
  return TodoSections(
    sortForList(pending),
    sortForList(exams),
    sortForList(tasks),
    sortDone(done),
  );
}

/// 列表排序，与 `TodoRepo.listTodos` 的 ORDER BY 逐条对应：
/// `CASE WHEN ddl = '' THEN 1 ELSE 0 END, ddl, priority DESC, id DESC`
List<Todo> sortForList(List<Todo> list) {
  final out = List<Todo>.from(list);
  out.sort((a, b) {
    final au = a.ddl.isEmpty ? 1 : 0;
    final bu = b.ddl.isEmpty ? 1 : 0;
    if (au != bu) return au - bu;
    if (a.ddl != b.ddl) return a.ddl.compareTo(b.ddl);
    if (a.priority != b.priority) return b.priority - a.priority;
    return b.id - a.id;
  });
  return out;
}

/// 已完成排序：`ORDER BY done_at DESC, id DESC`
List<Todo> sortDone(List<Todo> list) {
  final out = List<Todo>.from(list);
  out.sort((a, b) {
    if (a.doneAt != b.doneAt) return b.doneAt - a.doneAt;
    return b.id - a.id;
  });
  return out;
}

// ---------------- 文案 ----------------

/// '2026-10-14 23:59' → '10/14 23:59 · 明天'；空串 → '无截止'
/// 只有日期没有时刻（长度 < 16）时只显示日期 + 相对日
String ddlText(String ddl) {
  if (ddl.isEmpty) return '无截止';
  final date = parseDate(ddl.substring(0, 10));
  final time = ddl.length >= 16 ? ddl.substring(11, 16) : '';
  final rel = relativeDayText(date, today());
  return time.isEmpty
      ? '${date.month}/${date.day} · $rel'
      : '${date.month}/${date.day} $time · $rel';
}

/// 考试的固定时间段：'10 月 22 日 09:00–11:00'；没有时刻 → '时间待定'
String examTimeText(Todo t) {
  if (t.ddl.length < 16) return '时间待定';
  final d = parseDate(t.ddl.substring(0, 10));
  final span = t.endAt.length >= 16 ? '–${t.endAt.substring(11, 16)}' : '';
  return '${d.month} 月 ${d.day} 日 ${t.ddl.substring(11, 16)}$span';
}

/// 考试倒计时（相对今天）
String countdownOf(Todo t) {
  if (t.ddl.length < 10) return '';
  return countdownText(parseDate(t.ddl.substring(0, 10)), today());
}

/// 已完成条目上那行小字：'10/14 12:03 完成'；没有时间戳 → '已完成'
String doneAtText(Todo t) {
  if (t.doneAt <= 0) return '已完成';
  final d = DateTime.fromMillisecondsSinceEpoch(t.doneAt);
  return '${d.month}/${d.day} ${minToHHmm(d.hour * 60 + d.minute)} 完成';
}
