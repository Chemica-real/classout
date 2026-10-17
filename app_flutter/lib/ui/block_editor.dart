// 计划块的属性面板 —— 鸿蒙端 `view/PlanDayView.ets → BlockEditor()`：
// **右侧 84% 抽屉**（点空白关闭），标题固定、内容可滚。
//
// 字段顺序与鸿蒙端一致：
//   课程胶囊（只读） → `日期 时间（N 分钟）` → 日期 ‹ › → 开始时间（±15/±30 + 输入）
//   → 时长（±15/±30 + 输入） → 截止（考试不显示） → 备注（只读，可展开）
//   → 「这个待办还排在别的时段」 → 对半分 → 标记完成 / 移除此块 / 完成

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/note_pref.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/todo_generator.dart';
import '../domain/todo_list.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'theme.dart';

BackupBundle _with(
  BackupBundle b, {
  List<PlanBlock>? blocks,
  List<Todo>? todos,
  List<VirtualLesson>? lessons,
}) =>
    BackupBundle(
      app: b.app,
      version: b.version,
      exportedAt: b.exportedAt,
      semesters: b.semesters,
      sectionTimes: b.sectionTimes,
      courses: b.courses,
      rules: b.rules,
      overrides: b.overrides,
      todos: todos ?? b.todos,
      blocks: blocks ?? b.blocks,
      restWindows: b.restWindows,
      templates: b.templates,
      lessons: lessons ?? b.lessons,
    );

Future<void> showBlockEditor(
  BuildContext context, {
  required BackupBundle bundle,
  required PlanBlock block,
  required TimeWindow window,
  required void Function(BackupBundle next) onChanged,
  void Function(bool on)? onNotePref,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭块编辑',
    barrierColor: const Color(0x730C1220),
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => _Host(
      ctx: ctx,
      bundle: bundle,
      block: block,
      window: window,
      onChanged: onChanged,
      onNotePref: onNotePref,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: drawerCurve);
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

class _Host extends StatelessWidget {
  final BuildContext ctx;
  final BackupBundle bundle;
  final PlanBlock block;
  final TimeWindow window;
  final void Function(BackupBundle next) onChanged;
  final void Function(bool on)? onNotePref;

  const _Host({
    required this.ctx,
    required this.bundle,
    required this.block,
    required this.window,
    required this.onChanged,
    this.onNotePref,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: drawerWidthFactor,
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, floatTop, 0, floatGap),
            child: Glass(
              sheet: true,
              radius: 18,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: _Body(
                ctx: ctx,
                bundle: bundle,
                block: block,
                window: window,
                onChanged: onChanged,
                onNotePref: onNotePref,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  final BuildContext ctx;
  final BackupBundle bundle;
  final PlanBlock block;
  final TimeWindow window;
  final void Function(BackupBundle next) onChanged;
  final void Function(bool on)? onNotePref;

  const _Body({
    required this.ctx,
    required this.bundle,
    required this.block,
    required this.window,
    required this.onChanged,
    this.onNotePref,
  });

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late PlanBlock _b = widget.block;
  late bool _noteOpen = noteExpanded;

  /// 「删除这个待办」的二次确认（鸿蒙端 editorConfirmDeleteTodo）
  bool _confirmDeleteTodo = false;
  String? _error;
  late final TextEditingController _startCtrl;
  late final TextEditingController _durCtrl;

  @override
  void initState() {
    super.initState();
    _startCtrl = TextEditingController(text: minToHHmm(_b.startMin));
    _durCtrl = TextEditingController(text: '${_b.endMin - _b.startMin}');
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _durCtrl.dispose();
    super.dispose();
  }

  Todo? get _todo {
    for (final t in widget.bundle.todos) {
      if (t.id == _b.todoId) return t;
    }
    return null;
  }

  bool get _isExam => _todo?.category == TodoCategory.exam;

  VirtualLesson? get _lesson {
    if (_b.lessonId <= 0) return null;
    for (final l in widget.bundle.lessons) {
      if (l.id == _b.lessonId) return l;
    }
    return null;
  }

  Course? get _course {
    // ⚠️ lessonId 是**课时 id**，不是课程 id：要先查到那一讲，再拿它的 courseId
    final id =
        _b.todoId > 0 ? (_todo?.courseId ?? 0) : (_lesson?.courseId ?? 0);
    for (final c in widget.bundle.courses) {
      if (c.id == id) return c;
    }
    return null;
  }

  String get _title {
    final t = _todo;
    if (t != null) return t.title;
    final l = _lesson;
    if (l != null) return '第 ${l.seq} 讲 · ${l.title}';
    return _course?.label ?? '计划块';
  }

  /// 删除**整个待办**：它的所有块（含别的日期的）一起删；块本身由调用方在删完后关抽屉。
  void _deleteWholeTodo() {
    final todoId = _b.todoId;
    Navigator.of(widget.ctx).pop();
    widget.onChanged(_with(
      widget.bundle,
      todos: widget.bundle.todos.where((t) => t.id != todoId).toList(),
      blocks: widget.bundle.blocks.where((b) => b.todoId != todoId).toList(),
    ));
  }

  void _write({PlanBlock? block, Todo? todo}) {
    final nb = block ?? _b;
    final blocks =
        widget.bundle.blocks.map((x) => x.id == _b.id ? nb : x).toList();
    final todos = todo == null
        ? widget.bundle.todos
        : widget.bundle.todos.map((x) => x.id == todo.id ? todo : x).toList();
    // 虚拟课程的一讲：块标完成/取消时，把这一讲也一起标记（鸿蒙端同款联动）
    final lessons = nb.lessonId > 0 && nb.done != _b.done
        ? widget.bundle.lessons
            .map((l) => l.id == nb.lessonId
                ? VirtualLesson(
                    id: l.id,
                    courseId: l.courseId,
                    seq: l.seq,
                    title: l.title,
                    done: nb.done,
                    doneAt: nb.done ? DateTime.now().millisecondsSinceEpoch : 0,
                  )
                : l)
            .toList()
        : widget.bundle.lessons;
    // 虚拟课时刚被标记完成 → 按课程模板生成待办（鸿蒙端 generateForLesson 同款）
    var nextTodos = todos;
    final l = _lesson;
    final sem = widget.bundle.semester;
    if (nb.lessonId > 0 && nb.done && !_b.done && l != null && sem != null) {
      final outcome = generateForLesson(
        courses: widget.bundle.courses,
        rules: widget.bundle.rules,
        times: widget.bundle.sectionTimes,
        templates: widget.bundle.templates,
        todos: todos,
        sem: sem,
        lesson: l,
        date: nb.date,
        startMin: nb.startMin,
        endMin: nb.endMin,
        nextId: todos.fold<int>(0, (m, t) => t.id > m ? t.id : m),
      );
      if (outcome.created.isNotEmpty) {
        nextTodos = [...todos, ...outcome.created];
      }
    }
    setState(() => _b = nb);
    widget.onChanged(_with(widget.bundle,
        blocks: blocks, todos: nextTodos, lessons: lessons));
  }

  PlanBlock _copy({
    String? date,
    int? startMin,
    int? endMin,
    bool? done,
  }) =>
      PlanBlock(
        id: _b.id,
        todoId: _b.todoId,
        lessonId: _b.lessonId,
        date: date ?? _b.date,
        startMin: startMin ?? _b.startMin,
        endMin: endMin ?? _b.endMin,
        done: done ?? _b.done,
      );

  void _shiftDate(int days) {
    final d = addDays(parseDate(_b.date), days);
    _write(block: _copy(date: formatDate(d)));
  }

  /// 开始时间整体平移（时长不变）
  void _shiftStart(int delta) {
    final start = (_b.startMin + delta)
        .clamp(widget.window.startMin, widget.window.endMin - 15);
    final dur = _b.endMin - _b.startMin;
    final end = (start + dur).clamp(start + 15, widget.window.endMin);
    _write(block: _copy(startMin: start, endMin: end));
    _startCtrl.text = minToHHmm(start);
  }

  void _setStart(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) {
      setState(() => _error = '时间格式应为 HH:MM');
      return;
    }
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h > 23 || m > 59) {
      setState(() => _error = '时间格式应为 HH:MM');
      return;
    }
    _error = null;
    _shiftStart(h * 60 + m - _b.startMin);
  }

  void _setDuration(int minutes) {
    final dur = minutes.clamp(15, widget.window.endMin - _b.startMin);
    _write(block: _copy(endMin: _b.startMin + dur));
    _durCtrl.text = '$dur';
  }

  void _setDdl(String ddl) {
    final t = _todo;
    if (t == null) return;
    final copy = Todo.fromJson({
      'id': t.id,
      'title': t.title,
      'courseId': t.courseId,
      'category': t.category,
      'priority': t.priority,
      'ddl': ddl,
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
    _write(todo: copy);
  }

  /// 自定义截止：日期 + 时间（鸿蒙端 `pickDateTime`，分钟不限）
  Future<void> _pickCustomDdl() async {
    final raw = _todo?.ddl ?? '';
    final base = raw.length >= 10 ? parseDate(raw.substring(0, 10)) : today();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final hm = raw.length >= 16
        ? TimeOfDay(
            hour: int.tryParse(raw.substring(11, 13)) ?? 23,
            minute: int.tryParse(raw.substring(14, 16)) ?? 59)
        : const TimeOfDay(hour: 23, minute: 59);
    final time = await showTimePicker(context: context, initialTime: hm);
    if (time == null) return;
    String two(int n) => n < 10 ? '0$n' : '$n';
    _setDdl('${formatDate(date)} ${two(time.hour)}:${two(time.minute)}');
  }

  void _splitHalf() {
    final parts = halveMinutes(_b.endMin - _b.startMin);
    if (parts.length != 2) return;
    final other = PlanBlock(
      id: widget.bundle.blocks.fold<int>(0, (m, x) => x.id > m ? x.id : m) + 1,
      todoId: _b.todoId,
      lessonId: _b.lessonId,
      date: _b.date,
      startMin: _b.startMin + parts[0],
      endMin: _b.endMin,
      done: _b.done,
    );
    final blocks = widget.bundle.blocks
        .map((x) => x.id == _b.id ? _copy(endMin: _b.startMin + parts[0]) : x)
        .toList()
      ..add(other);
    widget.onChanged(_with(widget.bundle, blocks: blocks));
    Navigator.of(widget.ctx).pop();
  }

  List<PlanBlock> get _otherBlocks => widget.bundle.blocks
      .where((x) => x.todoId == _b.todoId && x.todoId > 0 && x.id != _b.id)
      .toList();

  @override
  Widget build(BuildContext context) {
    final course = _course;
    final dur = _b.endMin - _b.startMin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
            ),
            GestureDetector(
              onTap: () => Navigator.of(widget.ctx).pop(),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(left: 12, bottom: 4),
                child: Icon(Icons.close, size: 18, color: Color(0xFFA9B5C9)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (course != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: courseColor(course.colorIndex),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(course.label,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFEAF0FA))),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      '${_b.date} ${minToHHmm(_b.startMin)} - ${minToHHmm(_b.endMin)}'
                      '（$dur 分钟）',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF9BA7BD))),
                ),

                // 日期 ‹ ›
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('日期',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF94A0B5))),
                      ),
                      _Tap(
                        onTap: () => _shiftDate(-1),
                        child: const Icon(Icons.chevron_left,
                            size: 24, color: accentBlue),
                      ),
                      Text(_b.date,
                          style:
                              const TextStyle(fontSize: 12, color: inkPrimary)),
                      _Tap(
                        onTap: () => _shiftDate(1),
                        child: const Icon(Icons.chevron_right,
                            size: 24, color: accentBlue),
                      ),
                    ],
                  ),
                ),

                const _Label('开始时间（HH:MM）'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in const [-30, -15, 15, 30])
                      _Chip(
                        text: '${d > 0 ? '+' : ''}$d 分',
                        selected: false,
                        onTap: () => _shiftStart(d),
                      ),
                  ],
                ),
                _DarkField(
                  controller: _startCtrl,
                  hint: '14:30',
                  onSubmit: _setStart,
                ),

                const _Label('时长（分钟）'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in const [-15, 15, 30])
                      _Chip(
                        text: '${d > 0 ? '+' : ''}$d 分',
                        selected: false,
                        onTap: () => _setDuration(dur + d),
                      ),
                  ],
                ),
                _DarkField(
                  controller: _durCtrl,
                  hint: '60',
                  number: true,
                  onSubmit: (v) {
                    final n = int.tryParse(v);
                    if (n == null) {
                      setState(() => _error = '时长要填数字');
                      return;
                    }
                    _error = null;
                    _setDuration(n);
                  },
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_error!,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFFF8A8A))),
                  ),

                // 截止（考试不显示：它的 ddl 存的是开考时刻）
                if (_b.todoId > 0 && !_isExam) ...[
                  const _Label('截止时间'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Chip(
                        text: '今天 23:59',
                        selected: false,
                        onTap: () => _setDdl('${formatDate(today())} 23:59'),
                      ),
                      _Chip(
                        text: '明天 23:59',
                        selected: false,
                        onTap: () =>
                            _setDdl('${formatDate(addDays(today(), 1))} 23:59'),
                      ),
                      _Chip(
                        text: '3 天后',
                        selected: false,
                        onTap: () =>
                            _setDdl('${formatDate(addDays(today(), 3))} 23:59'),
                      ),
                      _Chip(
                        text: '无截止',
                        selected: false,
                        onTap: () => _setDdl(''),
                      ),
                      _Chip(
                        text: '自定义…',
                        selected: false,
                        onTap: _pickCustomDdl,
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        _todo?.ddl.isNotEmpty == true
                            ? ddlText(_todo!.ddl)
                            : '无截止',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF9BA7BD))),
                  ),
                ],

                // 备注（只读，可展开）
                if ((_todo?.note ?? '').isNotEmpty) ...[
                  const _Label('备注'),
                  Container(
                    width: double.infinity,
                    // 展开时固定最大高度 + **内部滚动**（不把抽屉撑满）
                    constraints: _noteOpen
                        ? const BoxConstraints(maxHeight: 140)
                        : null,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _noteOpen
                        ? SingleChildScrollView(
                            child: Text(_todo!.note,
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFFC3CDDE))),
                          )
                        : Text(_todo!.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFC3CDDE))),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _noteOpen = !_noteOpen);
                        noteExpanded = _noteOpen;
                        widget.onNotePref?.call(_noteOpen);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 2),
                        child: Text(_noteOpen ? '收起 ▴' : '展开 ▾',
                            style: const TextStyle(
                                fontSize: 10, color: accentBlue)),
                      ),
                    ),
                  ),
                ],

                if (_otherBlocks.isNotEmpty) ...[
                  const _Label('这个待办还排在别的时段'),
                  for (final o in _otherBlocks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                          '${o.date} ${minToHHmm(o.startMin)}-${minToHHmm(o.endMin)}'
                          '${o.done ? ' · 已完成' : ''}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFC3CDDE))),
                    ),
                ],

                // 对半分：只对待办块、非考试、且能拆成两块时
                if (_b.todoId > 0 &&
                    !_isExam &&
                    halveMinutes(dur).length == 2) ...[
                  const SizedBox(height: 12),
                  _BigAction(
                    text:
                        '对半分（${halveMinutes(dur)[0]} + ${halveMinutes(dur)[1]} 分钟）',
                    background: const Color(0x382E6BE6),
                    color: accentBlue,
                    onTap: _splitHalf,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _BigAction(
                text: _b.done ? '取消完成' : '标记完成',
                background: _b.done
                    ? Colors.white.withValues(alpha: 0.14)
                    : const Color(0xFF2E6BE6),
                color: _b.done ? const Color(0xFFC3CDDE) : Colors.white,
                onTap: () {
                  Navigator.of(widget.ctx).pop();
                  _write(block: _copy(done: !_b.done));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _BigAction(
                text: '移除此块',
                background: const Color(0x2ED64545),
                color: const Color(0xFFFF8A8A),
                onTap: () {
                  Navigator.of(widget.ctx).pop();
                  widget.onChanged(_with(widget.bundle,
                      blocks: widget.bundle.blocks
                          .where((x) => x.id != _b.id)
                          .toList()));
                },
              ),
            ),
          ],
        ),
        // 删除**整个待办**（它在别的日期的块也一起没）—— 必须二次确认
        if (_b.todoId > 0) ...[
          const SizedBox(height: 12),
          if (_confirmDeleteTodo)
            Row(
              children: [
                const Expanded(
                  child: Text('确定删除整个待办？它在别的日期的块也会一起没。',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFFFF8A8A))),
                ),
                GestureDetector(
                  onTap: () => setState(() => _confirmDeleteTodo = false),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('取消',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFFA9B5C9))),
                  ),
                ),
                GestureDetector(
                  onTap: _deleteWholeTodo,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD64545),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('删除待办',
                        style: TextStyle(fontSize: 13, color: Colors.white)),
                  ),
                ),
              ],
            )
          else
            _BigAction(
              text: '删除这个待办',
              background: const Color(0x24D64545), // rgba(214,69,69,0.14)
              color: const Color(0xFFFF8A8A),
              onTap: () => setState(() => _confirmDeleteTodo = true),
            ),
        ],
        const SizedBox(height: 8),
        _BigAction(
          text: '完成',
          background: Colors.white.withValues(alpha: 0.14),
          color: const Color(0xFFC3CDDE),
          onTap: () => Navigator.of(widget.ctx).pop(),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A0B5))),
      );
}

class _Tap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Tap({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: child,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E6BE6)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : const Color(0xFFC3CDDE))),
      ),
    );
  }
}

class _DarkField extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final bool number;
  final void Function(String value) onSubmit;
  const _DarkField({
    required this.controller,
    required this.hint,
    required this.onSubmit,
    this.number = false,
  });

  @override
  State<_DarkField> createState() => _DarkFieldState();
}

class _DarkFieldState extends State<_DarkField> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextField(
        controller: widget.controller,
        keyboardType:
            widget.number ? TextInputType.number : TextInputType.datetime,
        style: const TextStyle(fontSize: 13, color: inkPrimary),
        cursorColor: accentBlue,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF8B97AC)),
          isDense: true,
          enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0x24FFFFFF))),
          focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: accentBlue)),
        ),
        onSubmitted: widget.onSubmit,
        onEditingComplete: () => widget.onSubmit(widget.controller.text),
      ),
    );
  }
}

class _BigAction extends StatelessWidget {
  final String text;
  final Color background;
  final Color color;
  final VoidCallback onTap;
  const _BigAction({
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
                fontSize: 13, fontWeight: FontWeight.w500, color: color)),
      ),
    );
  }
}
