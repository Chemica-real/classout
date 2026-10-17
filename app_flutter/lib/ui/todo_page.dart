// 待办页 —— 照搬鸿蒙端 `view/TodoInbox.ets` 的四段列表：
//
//   待确认（下课自动生成，确认后才生效）  → 卡片带 删除/编辑/确认
//   即将考试（点一下可改考场）            → 红底卡片，右侧倒计时 + 「考完了」
//   待办                                  → 行首「○」，元信息 ddl · 预计 N 分钟
//   已完成（可收起）                      → 加灰 + 划掉，右侧「恢复/删除」
//
// 底部固定一条玻璃托盘：「+ 新建待办」（2 份宽，蓝）/「+ 考试」（1 份宽，金）。
// 页头（学期名 / 周次 / 补课 / 管理课程 / 同步）由外壳统一提供，见 course_header.dart。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/categories.dart';
import '../domain/todo_list.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';
import 'todo_editor.dart';

const Color _rowHint = Color(0xFF8B97AC);
const Color _rowMeta = Color(0xFF94A0B5);
const Color _rowNote = Color(0xFF7C8798);
const Color _chipInk = Color(0xFFEAF0FA);
const Color _chipCategory = Color(0xFFC3CDDE);
const Color _examInk = Color(0xFFFF8A8A);
const Color _examBg = Color(0x1FD64545); // rgba(214,69,69,0.12)
const Color _examEdge = Color(0x4DD64545); // rgba(214,69,69,0.30)

class TodoPage extends StatefulWidget {
  final BackupBundle bundle;
  final void Function(BackupBundle next) onChanged;

  /// 自定义待办类型（设置页里加的）
  final List<String> customCategories;

  /// 悬浮页头的高度（内容顶部留同样的空）
  final double topInset;

  /// 备注展开状态变了（外壳负责写 kv）
  final void Function(bool on)? onNotePref;

  const TodoPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    this.customCategories = const [],
    this.topInset = 0,
    this.onNotePref,
  });

  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  /// 「已完成」默认展开（就是要让人看见"它没丢"）
  bool _doneOpen = true;

  /// 二次确认删除的那一条
  int _pendingDeleteId = 0;

  List<String> get _custom => widget.customCategories;

  @override
  Widget build(BuildContext context) {
    final bundle = widget.bundle;
    final s = splitTodos(bundle.todos);
    final courses = {for (final c in bundle.courses) c.id: c};
    final hasTop = s.pending.isNotEmpty || s.exams.isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                16, 12 + widget.topInset, 16, 20 + tabBarInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- 待确认 ----
                if (s.pending.isNotEmpty) ...[
                  _SectionHeader(
                    title: '待确认',
                    count: '${s.pending.length} 条',
                    countColor: accentBlue,
                    hint: '下课自动生成，确认后才生效',
                  ),
                  for (final t in s.pending)
                    _PendingCard(
                      t: t,
                      course: courses[t.courseId],
                      categoryText: categoryLabel(t.category, _custom),
                      confirming: _pendingDeleteId == t.id,
                      onDelete: () => setState(() => _pendingDeleteId = t.id),
                      onCancelDelete: () =>
                          setState(() => _pendingDeleteId = 0),
                      onDeleteConfirmed: () {
                        setState(() => _pendingDeleteId = 0);
                        widget.onChanged(_without(t.id));
                      },
                      onEdit: () => _openEditor(context, existing: t),
                      onConfirm: () => widget.onChanged(_mutate(t.id, (x) {
                        x.status = TodoStatus.active;
                        x.confirmedAt = DateTime.now().millisecondsSinceEpoch;
                      })),
                    ),
                ],

                // ---- 即将考试 ----
                if (s.exams.isNotEmpty) ...[
                  _SectionHeader(
                    title: '即将考试',
                    count: '${s.exams.length} 场',
                    countColor: _examInk,
                    hint: '点一下可改考场',
                    top: s.pending.isNotEmpty ? 14 : 0,
                  ),
                  for (final t in s.exams)
                    _ExamCard(
                      t: t,
                      course: courses[t.courseId],
                      countdown: countdownOf(t),
                      onOpen: () => _openEditor(context, existing: t),
                      onDone: () => widget.onChanged(_mutate(t.id, (x) {
                        x.status = TodoStatus.done;
                        x.doneAt = DateTime.now().millisecondsSinceEpoch;
                      })),
                    ),
                ],

                // ---- 待办 ----
                _SectionHeader(
                  title: '待办',
                  count: '${s.tasks.length} 条',
                  countColor: _rowMeta,
                  top: hasTop ? 14 : 0,
                ),
                if (s.tasks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      '暂无待办。下课之后，配了模板的课程会自动生成待办到这里。',
                      style: TextStyle(fontSize: 12, color: _rowHint),
                    ),
                  ),
                for (final t in s.tasks)
                  _ActiveRow(
                    t: t,
                    course: courses[t.courseId],
                    categoryText: categoryLabel(t.category, _custom),
                    onComplete: () => widget.onChanged(_mutate(t.id, (x) {
                      x.status = TodoStatus.done;
                      x.doneAt = DateTime.now().millisecondsSinceEpoch;
                    })),
                    onOpen: () => _openEditor(context, existing: t),
                  ),

                // ---- 已完成 ----
                if (s.done.isNotEmpty) ...[
                  _DoneHeader(
                    count: s.done.length,
                    open: _doneOpen,
                    onToggle: () => setState(() => _doneOpen = !_doneOpen),
                  ),
                  if (_doneOpen)
                    for (final t in s.done)
                      _DoneRow(
                        t: t,
                        categoryText: categoryLabel(t.category, _custom),
                        confirming: _pendingDeleteId == t.id,
                        onDelete: () => setState(() => _pendingDeleteId = t.id),
                        onCancelDelete: () =>
                            setState(() => _pendingDeleteId = 0),
                        onDeleteConfirmed: () {
                          setState(() => _pendingDeleteId = 0);
                          widget.onChanged(_without(t.id));
                        },
                        onRestore: () => widget.onChanged(_mutate(t.id, (x) {
                          x.status = TodoStatus.active;
                          x.doneAt = 0;
                        })),
                        onOpen: () => _openEditor(context, existing: t),
                      ),
                ],
              ],
            ),
          ),
        ),
        // ---- 底部行动托盘 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(
              floatSide, 0, floatSide, tabBarInset + floatGap),
          child: Glass(
            sheet: true,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _TrayButton(
                    text: '+ 新建待办',
                    background: const Color(0xFF2E6BE6),
                    color: Colors.white,
                    onTap: () => _openEditor(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: _TrayButton(
                    text: '+ 考试',
                    background: const Color(0x33B26B00), // rgba(178,107,0,0.20)
                    color: const Color(0xFFE8B25C),
                    onTap: () => _openEditor(context, asExam: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- 数据改动 ----------------

  /// 复制一份 bundle、改一条待办（仓库只有 replaceAll，先这样；接原生库后改增量更新）
  BackupBundle _mutate(int id, void Function(Todo) change) {
    final todos = widget.bundle.todos.map((t) {
      if (t.id != id) return t;
      final copy = Todo.fromJson({
        'id': t.id,
        'title': t.title,
        'courseId': t.courseId,
        'category': t.category,
        'priority': t.priority,
        'ddl': t.ddl,
        'endAt': t.endAt,
        'estimateMin': t.estimateMin,
        'status': t.status,
        'note': t.note,
        'source': t.source,
        'generationKey': t.generationKey,
        'submitChannel': t.submitChannel,
        'repeatRule': t.repeatRule,
        'photos': t.photos,
        'createdAt': t.createdAt,
        'confirmedAt': t.confirmedAt,
        'doneAt': t.doneAt,
      });
      change(copy);
      return copy;
    }).toList();
    return _copyWith(todos: todos);
  }

  BackupBundle _without(int id) =>
      _copyWith(todos: widget.bundle.todos.where((t) => t.id != id).toList());

  BackupBundle _copyWith({List<Todo>? todos}) => BackupBundle(
        app: widget.bundle.app,
        version: widget.bundle.version,
        exportedAt: widget.bundle.exportedAt,
        semesters: widget.bundle.semesters,
        sectionTimes: widget.bundle.sectionTimes,
        courses: widget.bundle.courses,
        rules: widget.bundle.rules,
        overrides: widget.bundle.overrides,
        todos: todos ?? widget.bundle.todos,
        blocks: widget.bundle.blocks,
        restWindows: widget.bundle.restWindows,
        templates: widget.bundle.templates,
        lessons: widget.bundle.lessons,
      );

  Future<void> _openEditor(BuildContext context,
      {Todo? existing, bool asExam = false}) async {
    final result = await showTodoEditor(context,
        courses: widget.bundle.courses,
        existing: existing,
        asExam: asExam,
        onNotePref: widget.onNotePref);
    if (result == null) return;
    if (result.delete) {
      if (existing != null) widget.onChanged(_without(existing.id));
      return;
    }
    final draft = result.todo;
    if (draft == null) return;
    if (existing == null) {
      final nextId =
          widget.bundle.todos.fold<int>(0, (m, t) => t.id > m ? t.id : m) + 1;
      draft.id = nextId;
      widget.onChanged(_copyWith(todos: [...widget.bundle.todos, draft]));
      return;
    }
    widget.onChanged(_copyWith(todos: [
      for (final t in widget.bundle.todos)
        if (t.id == draft.id) draft else t,
    ]));
  }
}

// ---------------- 小节标题 ----------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final String count;
  final Color countColor;
  final String? hint;
  final double top;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.countColor,
    this.hint,
    this.top = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: inkPrimary)),
          const SizedBox(width: 6),
          Text(count, style: TextStyle(fontSize: 12, color: countColor)),
          const Spacer(),
          if (hint != null)
            Text(hint!, style: const TextStyle(fontSize: 11, color: _rowHint)),
        ],
      ),
    );
  }
}

class _DoneHeader extends StatelessWidget {
  final int count;
  final bool open;
  final VoidCallback onToggle;
  const _DoneHeader(
      {required this.count, required this.open, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text('已完成',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w500, color: _rowMeta)),
          const SizedBox(width: 6),
          Text('$count 条',
              style: const TextStyle(fontSize: 12, color: _rowNote)),
          const Spacer(),
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(open ? '收起' : '展开',
                      style: const TextStyle(fontSize: 11, color: accentBlue)),
                  Icon(open ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: accentBlue),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 小零件 ----------------

/// 课程色胶囊（鸿蒙端：底色 = 课程色，白字）
class _CourseChip extends StatelessWidget {
  final Course course;
  final double fontSize;
  const _CourseChip({required this.course, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding:
          EdgeInsets.symmetric(horizontal: fontSize >= 11 ? 5 : 4, vertical: 1),
      decoration: BoxDecoration(
        color: courseColor(course.colorIndex),
        borderRadius: BorderRadius.circular(fontSize >= 11 ? 4 : 3),
      ),
      child: Text(course.label,
          style: TextStyle(fontSize: fontSize, color: _chipInk)),
    );
  }
}

/// 类型小标签（中性灰，和彩色课程胶囊区分；「无」不画）
class _CategoryChip extends StatelessWidget {
  final String text;
  const _CategoryChip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 10, color: _chipCategory)),
    );
  }
}

class _SmallButton extends StatelessWidget {
  final String text;
  final Color color;
  final VoidCallback onTap;
  const _SmallButton(
      {required this.text, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ),
    );
  }
}

/// 卡片/行统一用的玻璃底（鸿蒙端 `glassCard`：**不模糊**，只靠半透明透气）
class _RowCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final Color? border;
  final double radius;
  const _RowCard({
    required this.child,
    this.color = glassTintRow,
    this.border,
    this.radius = glassRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: border == null ? null : Border.all(color: border!),
        ),
        child: child,
      ),
    );
  }
}

// ---------------- 三种卡片 ----------------

class _PendingCard extends StatelessWidget {
  final Todo t;
  final Course? course;
  final String categoryText;
  final bool confirming;
  final VoidCallback onDelete;
  final VoidCallback onCancelDelete;
  final VoidCallback onDeleteConfirmed;
  final VoidCallback onEdit;
  final VoidCallback onConfirm;

  const _PendingCard({
    required this.t,
    required this.course,
    required this.categoryText,
    required this.confirming,
    required this.onDelete,
    required this.onCancelDelete,
    required this.onDeleteConfirmed,
    required this.onEdit,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return _RowCard(
      border: glassEdgeSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (course != null) _CourseChip(course: course!, fontSize: 11),
              if (categoryText.isNotEmpty) _CategoryChip(categoryText),
              Expanded(
                child: Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
              ),
            ],
          ),
          if (t.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(t.note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _rowNote)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(ddlText(t.ddl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: inkSecondary)),
                ),
                if (confirming) ...[
                  _SmallButton(
                      text: '确认删除', color: dangerRed, onTap: onDeleteConfirmed),
                  _SmallButton(
                      text: '取消',
                      color: const Color(0xFFA9B5C9),
                      onTap: onCancelDelete),
                ] else ...[
                  _SmallButton(text: '删除', color: dangerRed, onTap: onDelete),
                  _SmallButton(
                      text: '编辑',
                      color: const Color(0xFFA9B5C9),
                      onTap: onEdit),
                  _SmallButton(text: '确认', color: accentBlue, onTap: onConfirm),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveRow extends StatelessWidget {
  final Todo t;
  final Course? course;
  final String categoryText;
  final VoidCallback onComplete;
  final VoidCallback onOpen;

  const _ActiveRow({
    required this.t,
    required this.course,
    required this.categoryText,
    required this.onComplete,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: _RowCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onComplete,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Text('○',
                    style: TextStyle(
                        fontSize: 18, color: Color(0xFFDCE4F0), height: 1.1)),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (course != null)
                        _CourseChip(course: course!, fontSize: 10),
                      if (categoryText.isNotEmpty) _CategoryChip(categoryText),
                      Expanded(
                        child: Text(t.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, color: inkPrimary)),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('${ddlText(t.ddl)} · 预计 ${t.estimateMin} 分钟',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _rowMeta)),
                  ),
                  if (t.note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(t.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 11, color: _rowNote)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExamCard extends StatelessWidget {
  final Todo t;
  final Course? course;
  final String countdown;
  final VoidCallback onOpen;
  final VoidCallback onDone;

  const _ExamCard({
    required this.t,
    required this.course,
    required this.countdown,
    required this.onOpen,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: _RowCard(
        color: _examBg,
        border: _examEdge,
        radius: 10,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (course != null)
                        _CourseChip(course: course!, fontSize: 10),
                      Expanded(
                        child: Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: inkPrimary)),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                        '${examTimeText(t)}${t.note.isNotEmpty ? ' · ${t.note}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _rowMeta)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(countdown,
                    style: const TextStyle(fontSize: 12, color: _examInk)),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GestureDetector(
                    onTap: onDone,
                    behavior: HitTestBehavior.opaque,
                    child: const Text('考完了',
                        style: TextStyle(fontSize: 11, color: accentBlue)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  final Todo t;
  final String categoryText;
  final bool confirming;
  final VoidCallback onDelete;
  final VoidCallback onCancelDelete;
  final VoidCallback onDeleteConfirmed;
  final VoidCallback onRestore;
  final VoidCallback onOpen;

  const _DoneRow({
    required this.t,
    required this.categoryText,
    required this.confirming,
    required this.onDelete,
    required this.onCancelDelete,
    required this.onDeleteConfirmed,
    required this.onRestore,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final meta = '${doneAtText(t)}'
        '${t.estimateMin > 0 ? ' · 预计 ${t.estimateMin} 分钟' : ''}';
    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: _RowCard(
        color: const Color(0x0DFFFFFF), // rgba(255,255,255,0.05)
        border: const Color(0x14FFFFFF), // rgba(255,255,255,0.08)
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: Icon(Icons.check, size: 16, color: _rowNote),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (categoryText.isNotEmpty) _CategoryChip(categoryText),
                      Expanded(
                        child: Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              color: inkTertiary,
                              decoration: TextDecoration.lineThrough,
                              decorationColor: _rowNote,
                            )),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _rowNote)),
                  ),
                ],
              ),
            ),
            if (confirming) ...[
              _SmallButton(
                  text: '确认删除', color: dangerRed, onTap: onDeleteConfirmed),
              _SmallButton(
                  text: '取消',
                  color: const Color(0xFFA9B5C9),
                  onTap: onCancelDelete),
            ] else ...[
              _SmallButton(text: '恢复', color: accentBlue, onTap: onRestore),
              _SmallButton(text: '删除', color: dangerRed, onTap: onDelete),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrayButton extends StatelessWidget {
  final String text;
  final Color background;
  final Color color;
  final VoidCallback onTap;
  const _TrayButton({
    required this.text,
    required this.background,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: color)),
      ),
    );
  }
}
