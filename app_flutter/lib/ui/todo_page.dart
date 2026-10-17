// 待办页（第一版）：四段列表 + 完成/确认 + 新建。
//
// 与鸿蒙端一致的四段：待确认 → 即将考试 → 待办 → 已完成（不消失，加灰划掉）。
// 数据来自 ClassOutRepo；每次改动通过 `onChanged(fn)` 交给外壳写回仓库。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/categories.dart';
import '../domain/todo_list.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'palette.dart';
import 'todo_editor.dart';

class TodoPage extends StatelessWidget {
  final BackupBundle bundle;
  final void Function(BackupBundle next) onChanged;

  /// 自定义待办类型（设置页里加的）
  final List<String> customCategories;

  const TodoPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    this.customCategories = const [],
  });

  List<String> get _customCategories => customCategories;

  @override
  Widget build(BuildContext context) {
    final s = splitTodos(bundle.todos);
    final courses = {for (final c in bundle.courses) c.id: c};

    return Column(
      children: [
        _Header(total: bundle.todos.length, pending: s.pending.length),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.pending.isNotEmpty)
                  _Section('待确认', subtitle: '下课自动生成，确认后才生效'),
                for (final t in s.pending)
                  _TodoCard(
                    t: t,
                    course: courses[t.courseId],
                    categoryText: categoryLabel(t.category, _customCategories),
                    actionLabel: '确认',
                    onAction: () => onChanged(_mutate(t.id, (x) {
                      x.status = TodoStatus.active;
                      x.confirmedAt = DateTime.now().millisecondsSinceEpoch;
                    })),
                  ),
                if (s.exams.isNotEmpty) _Section('即将考试', subtitle: '点一下可改考场'),
                for (final t in s.exams)
                  _ExamCard(
                    t: t,
                    countdown: countdownOf(t),
                    onDone: () => onChanged(_mutate(t.id, (x) {
                      x.status = TodoStatus.done;
                      x.doneAt = DateTime.now().millisecondsSinceEpoch;
                    })),
                  ),
                _Section('待办'),
                if (s.tasks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      '暂无待办。下课之后，配了模板的课程会自动生成待办到这里。',
                      style: TextStyle(fontSize: 12, color: inkTertiary),
                    ),
                  ),
                for (final t in s.tasks)
                  _TodoCard(
                    t: t,
                    course: courses[t.courseId],
                    categoryText: categoryLabel(t.category, _customCategories),
                    onToggle: () => onChanged(_mutate(t.id, (x) {
                      x.status = TodoStatus.done;
                      x.doneAt = DateTime.now().millisecondsSinceEpoch;
                    })),
                  ),
                if (s.done.isNotEmpty) _Section('已完成', subtitle: '加灰显示，可以恢复'),
                for (final t in s.done)
                  _TodoCard(
                    t: t,
                    course: courses[t.courseId],
                    categoryText: categoryLabel(t.category, _customCategories),
                    done: true,
                    subtitle: doneAtText(t),
                    onToggle: () => onChanged(_mutate(t.id, (x) {
                      x.status = TodoStatus.active;
                      x.doneAt = 0;
                    })),
                  ),
                const SizedBox(height: 10),
                _NewButtons(
                  onNew: () => _openEditor(context),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 复制一份 bundle、改一条待办（仓库只有 replaceAll，先这样；接原生库后改增量更新）
  BackupBundle _mutate(int id, void Function(Todo) change) {
    final todos = bundle.todos.map((t) {
      if (t.id != id) return t;
      final copy = Todo.fromJson({
        'id': t.id, 'title': t.title, 'courseId': t.courseId, 'category': t.category,
        'priority': t.priority, 'ddl': t.ddl, 'endAt': t.endAt,
        'estimateMin': t.estimateMin, 'status': t.status, 'note': t.note,
        'source': t.source, 'generationKey': t.generationKey,
        'submitChannel': t.submitChannel, 'repeatRule': t.repeatRule,
        'photos': t.photos, 'createdAt': t.createdAt,
        'confirmedAt': t.confirmedAt, 'doneAt': t.doneAt,
      });
      change(copy);
      return copy;
    }).toList();
    return _copyWith(todos: todos);
  }

  BackupBundle _copyWith({List<Todo>? todos}) => BackupBundle(
        app: bundle.app,
        version: bundle.version,
        exportedAt: bundle.exportedAt,
        semesters: bundle.semesters,
        sectionTimes: bundle.sectionTimes,
        courses: bundle.courses,
        rules: bundle.rules,
        overrides: bundle.overrides,
        todos: todos ?? bundle.todos,
        blocks: bundle.blocks,
      );

  Future<void> _openEditor(BuildContext context) async {
    final draft = await showTodoEditor(context, courses: bundle.courses);
    if (draft == null) return;
    final nextId = bundle.todos.fold<int>(0, (m, t) => t.id > m ? t.id : m) + 1;
    draft.id = nextId;
    onChanged(_copyWith(todos: [...bundle.todos, draft]));
  }
}

// ---------------- 页头 ----------------

class _Header extends StatelessWidget {
  final int total;
  final int pending;
  const _Header({required this.total, required this.pending});

  @override
  Widget build(BuildContext context) {
    return Glass(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          const Text('待办',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: inkPrimary)),
          const SizedBox(width: 10),
          Text('$total 条', style: const TextStyle(fontSize: 12, color: inkTertiary)),
          const Spacer(),
          if (pending > 0)
            Text('待确认 $pending',
                style: const TextStyle(fontSize: 12, color: accentBlue)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _Section(this.title, {this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: inkPrimary)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: inkTertiary)),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------- 卡片 ----------------

class _TodoCard extends StatelessWidget {
  final Todo t;
  final Course? course;
  final String categoryText;
  final bool done;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onToggle;

  const _TodoCard({
    required this.t,
    required this.course,
    required this.categoryText,
    this.done = false,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = done ? inkTertiary : inkPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 10),
                child: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: done ? goodGreen : inkSecondary,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (categoryText.isNotEmpty) ...[
                        _Tag(categoryText),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          t.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: textColor,
                            decoration: done ? TextDecoration.lineThrough : null,
                            decorationColor: inkTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (course != null) ...[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: courseColor(course!.colorIndex),
                              shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 4),
                        Text(course!.label,
                            style: const TextStyle(fontSize: 11, color: inkSecondary)),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          subtitle ?? ddlText(t.ddl),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: inkTertiary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: accentBlue,
                ),
                child: Text(actionLabel!, style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExamCard extends StatelessWidget {
  final Todo t;
  final String countdown;
  final VoidCallback onDone;
  const _ExamCard({required this.t, required this.countdown, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.event_note, size: 18, color: Color(0xFFE0B050)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title,
                      style: const TextStyle(fontSize: 14, color: inkPrimary)),
                  const SizedBox(height: 3),
                  Text('$countdown · ${examTimeText(t)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: inkTertiary)),
                ],
              ),
            ),
            TextButton(
              onPressed: onDone,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                foregroundColor: goodGreen,
              ),
              child: const Text('标记完成', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10, color: inkSecondary)),
    );
  }
}

// ---------------- 新建 ----------------

class _NewButtons extends StatelessWidget {
  final VoidCallback onNew;
  const _NewButtons({required this.onNew});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建待办'),
            style: FilledButton.styleFrom(
              backgroundColor: accentBlue.withValues(alpha: 0.22),
              foregroundColor: inkPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
