// 计划页（第一版）：日/三日时间轴 + 课表灰带 + 计划块 + 截止标记 + 待安排托盘。
//
// 几何完全沿用 PlanMath：1 分钟 = 1vp，时间窗默认 07:00–24:00，吸附 15 分钟。
// 还没做的：拖动/缩放（PlanMath 的 dropRange/moveRange/resizeRange 已移植并有 fixtures，
// 等交互打磨时接上）、属性面板里的改时间、三日视图的横向拖拽。

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/todo_list.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'block_editor.dart';
import 'timetable_page.dart' show gridPad;
import 'palette.dart';

/// 三日视图列头高度（鸿蒙 `H_COLHEAD = 34`）
const double colHeadH = 34;

class PlanPage extends StatefulWidget {
  final BackupBundle bundle;
  final void Function(BackupBundle next) onChanged;

  /// 计划页画哪一段（设置页可改）
  final TimeWindow window;

  /// 不可排时段：优先用库里的，空则用默认值
  final List<RestWindow> restWindows;

  /// 悬浮页头的高度（计划页自己的日期条叠在它下面）
  final double topInset;

  /// 备注展开状态变了（外壳负责写 kv）
  final void Function(bool on)? onNotePref;

  /// 打开时看哪天 / 是不是三日视图（默认今天、单日）——截图和测试要用
  final DateTime? initialDay;
  final bool initialThreeDay;

  /// 取"现在"的方式。默认 `DateTime.now`，测试可以注入固定时钟。
  /// ⚠️ 为什么需要它：⚡找空档的起点是"今天就从当前时刻开始找"，
  /// 用真实时钟的话，同一条测试白天过、半夜挂（23:25 之后直到 24:00 都被
  /// "睡觉 23:30–24:00" 挡住）—— 实测踩过一次。
  final DateTime Function() now;
  const PlanPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    this.window = defaultWindow,
    this.restWindows = const [],
    this.topInset = 0,
    this.onNotePref,
    this.initialDay,
    this.initialThreeDay = false,
    this.now = DateTime.now,
  });

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  static const double _axisW = 46;

  late DateTime _day;
  late bool _threeDay;
  int _selectedTodoId = 0; // 托盘里选中、等着落到网格上的那条
  int _selectedLessonId = 0; // 托盘里选中的虚拟课程课时（0 = 没选）

  /// 网格里选中的块（鸿蒙两步模型：第一下选中、第二下开编辑窗）
  int _selectedBlockId = 0;

  /// 待安排托盘是否展开（鸿蒙端 TraySummonBar ↔ TodoPool）
  bool _trayOpen = false;

  /// 日期条实测高度（首帧用估算值）
  double _dayBarH = 68;

  /// 瞬时提示（鸿蒙端 showHint）：不占布局、1.8 秒自动消失
  String _hint = '';
  Timer? _hintTimer;

  /// 双指缩放预览：正在缩的块 id 与预览结束分钟（0 = 没在缩）
  int _pinchId = 0;
  int _pinchEndMin = 0;

  /// 当前按在画面上的手指（只用于识别双指缩放；不参与手势竞技场）
  final Map<int, Offset> _pointers = {};
  double _pinchBaseDist = 0;

  // ---- 拖动 / 缩放（见 domain/plan_math.dart 的 moveRange / resizeRange / edgeScroll*）----
  final ScrollController _scroll = ScrollController();
  final GlobalKey _gridKey = GlobalKey();

  /// 正在拖的块 id（0 = 没在拖）
  int _dragId = 0;

  /// 拖的是底边（缩放）还是整块（移动）
  bool _dragResize = false;

  /// 拖拽目标列（-1 = 不跨天 / 缩放中）；跨天松手时按它改日期
  int _dragCol = -1;


  /// 手指按下时的窗口 y
  double _dragTouchStartY = 0;

  /// 按下时的滚动位置
  double _dragScrollStart = 0;

  /// 预览用的偏移（分钟）：拖动过程中只改这个，松手才写数据
  int _dragDeltaMin = 0;

  @override
  void dispose() {
    _hintTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 弹一条瞬时提示（空白串 = 立刻清掉）
  void _showHint(String text) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() => _hint = text);
    if (text.isEmpty) return;
    _hintTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _hint = '');
    });
  }

  /// 网格在屏幕上的可视范围（自动滚动要用）
  Rect? _gridRect() {
    final ctx = _gridKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final off = box.localToGlobal(Offset.zero);
    return off & box.size;
  }

  /// 全局 x 落在第几列（用鸿蒙 PlanLayout 的同一套列几何）
  int _colOfGlobal(double x) {
    final rect = _gridRect();
    if (rect == null) return -1;
    return planColumnAtX(rect.width, _days.length, x - rect.left);
  }

  void _startDrag(PlanBlock b, bool resize, Offset pos) {
    // 两步模型（domain `canBeginDrag`）：只有已选中的块才能开始拖
    if (!canBeginDrag(_selectedBlockId, b.id)) return;
    setState(() {
      _dragId = b.id;
      _dragResize = resize;
      _dragTouchStartY = pos.dy;
      _dragCol = resize ? -1 : _colOfGlobal(pos.dx);
      _dragScrollStart = _scroll.hasClients ? _scroll.offset : 0;
      _dragDeltaMin = 0;
    });
  }

  void _updateDrag(Offset pos) {
    if (_dragId == 0) return;
    final globalY = pos.dy;
    if (!_dragResize) _dragCol = _colOfGlobal(pos.dx);
    // 贴边自动滚动：手指在上下 edgeZone 内就把视图推一推
    const edgeZone = 56.0;
    const maxStep = 14.0;
    final rect = _gridRect();
    if (rect != null) {
      final dir = edgeScrollDirection(globalY.round(), rect.top.round(),
          rect.bottom.round(), edgeZone.round());
      if (dir != 0 && _scroll.hasClients) {
        final depth = edgeScrollDepth(globalY.round(), rect.top.round(),
            rect.bottom.round(), edgeZone.round());
        final step = edgeScrollStep(depth, edgeZone.round(), maxStep.round());
        final target = (_scroll.offset + dir * step)
            .clamp(0.0, _scroll.position.maxScrollExtent);
        _scroll.jumpTo(target);
      }
    }
    // 块的位移 = 手指位移 + 滚动量（符号必须是加，见 fixtures 里那条断言）
    final scrollDelta =
        (_scroll.hasClients ? _scroll.offset : 0) - _dragScrollStart;
    final offset = dragOffsetWithScroll(
        (globalY - _dragTouchStartY).round(), scrollDelta.round());
    setState(() => _dragDeltaMin = snap(offset));
  }

  void _endDrag() {
    final id = _dragId;
    final resize = _dragResize;
    final delta = _dragDeltaMin;
    final col = _dragCol;
    setState(() {
      _dragId = 0;
      _dragDeltaMin = 0;
      _dragCol = -1;
    });
    if (id == 0) return;
    final b = widget.bundle.blocks.firstWhere((x) => x.id == id);
    // 跨天：松手时落在别的列 → 改日期（缩放不跨天）
    final days = _days;
    final targetDate = (!resize && col >= 0 && col < days.length)
        ? formatDate(days[col])
        : b.date;
    if (delta == 0 && targetDate == b.date) return;
    final range = resize
        ? resizeRange(_axis, b.startMin, b.endMin, delta)
        : moveRange(_axis, b.startMin, b.endMin, delta);
    widget.onChanged(_withBlocks([
      for (final x in widget.bundle.blocks)
        if (x.id != id)
          x
        else
          PlanBlock(
            id: x.id,
            todoId: x.todoId,
            lessonId: x.lessonId,
            date: targetDate,
            startMin: range[0],
            endMin: range[1],
            done: x.done,
          ),
    ]));
  }

  @override
  void initState() {
    super.initState();
    _day = widget.initialDay ??
        DateTime(widget.now().year, widget.now().month, widget.now().day);
    _threeDay = widget.initialThreeDay;
  }

  Semester get _sem => widget.bundle.semester!;

  TimeAxis get _axis => TimeAxis(widget.window);

  List<DateTime> get _days {
    if (!_threeDay) return [_day];
    return [for (var i = 0; i < 3; i++) addDays(_day, i)];
  }

  void _shift(int days) => setState(() => _day = addDays(_day, days));

  void _jumpToday() => setState(() => _day = today());

  // ---------------- 数据 ----------------

  /// 某天的课（灰带）
  List<CourseSession> _sessionsOn(DateTime day) {
    final sessions = computeWeekSessions(
        _sem,
        widget.bundle.courses,
        widget.bundle.rules,
        widget.bundle.overrides,
        widget.bundle.sectionTimes,
        weekOfDate(_sem, day));
    final ds = formatDate(day);
    return sessions.where((s) => s.date == ds).toList();
  }

  /// 某天的计划块
  List<PlanBlock> _blocksOn(DateTime day) =>
      widget.bundle.blocks.where((b) => b.date == formatDate(day)).toList();

  /// 某天的截止分组（★ 考试不算截止，这条在 ddlGroupsOn 里）
  List<DdlGroup> _ddlOn(DateTime day) => ddlGroupsOn(
      widget.bundle.todos, formatDate(day), _axis.startMin, _axis.endMin);

  /// 某一天适用的不可排时段：`weekday == 0` 表示每天；裁到当前时间窗内
  List<RestWindow> _restsOn(DateTime d) {
    final wd = weekdayOf(d);
    final out = <RestWindow>[];
    // 库里没有就用默认（午休/晚饭/睡觉/凌晨），与鸿蒙端 defaultRestWindows 一致
    final source = widget.restWindows.isNotEmpty
        ? widget.restWindows
        : [
            for (final w in defaultRestWindows())
              RestWindow(
                weekday: 0,
                startMin: w.$1,
                endMin: w.$2,
                label: w.$1 >= 23 * 60
                    ? '睡觉'
                    : (w.$1 >= 17 * 60
                        ? '晚饭'
                        : (w.$1 >= 12 * 60 ? '午休' : '睡觉')),
              ),
          ];
    for (final w in source) {
      if (w.weekday != 0 && w.weekday != wd) continue;
      final from = w.startMin < _axis.startMin ? _axis.startMin : w.startMin;
      final to = w.endMin > _axis.endMin ? _axis.endMin : w.endMin;
      if (to - from < 10) continue;
      out.add(RestWindow(
          id: w.id,
          weekday: w.weekday,
          startMin: from,
          endMin: to,
          label: w.label));
    }
    return out;
  }

  /// 库里有就用库里的，空则退回默认（午休/晚饭/睡觉）
  List<List<int>> _restRanges() {
    if (widget.restWindows.isNotEmpty) {
      return [
        for (final w in widget.restWindows) [w.startMin, w.endMin]
      ];
    }
    return [
      for (final w in defaultRestWindows()) [w.$1, w.$2]
    ];
  }

  /// 可以排进计划的虚拟课程课时：未完成、且还没排过
  List<VirtualLesson> get _lessonPool => [
        for (final l in widget.bundle.lessons)
          if (!l.done && !widget.bundle.blocks.any((b) => b.lessonId == l.id)) l
      ];

  List<Todo> get _pool =>
      sortPoolTodos(selectPoolTodos(widget.bundle.todos, widget.bundle.blocks));

  Todo? _todoOf(int id) {
    for (final t in widget.bundle.todos) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ---------------- 改动 ----------------

  BackupBundle _withBlocks(List<PlanBlock> blocks) => BackupBundle(
        app: widget.bundle.app,
        version: widget.bundle.version,
        exportedAt: widget.bundle.exportedAt,
        semesters: widget.bundle.semesters,
        sectionTimes: widget.bundle.sectionTimes,
        courses: widget.bundle.courses,
        rules: widget.bundle.rules,
        overrides: widget.bundle.overrides,
        todos: widget.bundle.todos,
        blocks: blocks,
        restWindows: widget.bundle.restWindows,
        templates: widget.bundle.templates,
        lessons: widget.bundle.lessons,
      );

  int _nextBlockId() =>
      widget.bundle.blocks.fold<int>(0, (m, b) => b.id > m ? b.id : m) + 1;

  void _place(DateTime day, int startMin, int durationMin) {
    final end = startMin + normalizeDuration(durationMin);
    if (_selectedLessonId > 0) {
      // 虚拟课程的一讲：todoId=0、lessonId 指向这一讲
      final block = PlanBlock(
        id: _nextBlockId(),
        todoId: 0,
        lessonId: _selectedLessonId,
        date: formatDate(day),
        startMin: startMin,
        endMin: end,
        done: false,
      );
      widget.onChanged(_withBlocks([...widget.bundle.blocks, block]));
      setState(() => _selectedLessonId = 0);
      _showHint('已排到 ${minToHHmm(startMin)}');
      return;
    }
    final todo = _todoOf(_selectedTodoId);
    if (todo == null) return;
    final block = PlanBlock(
      id: _nextBlockId(),
      todoId: todo.id,
      date: formatDate(day),
      startMin: startMin,
      endMin: end,
      done: false,
    );
    widget.onChanged(_withBlocks([...widget.bundle.blocks, block]));
    setState(() => _selectedTodoId = 0);
    _showHint('已排到 ${minToHHmm(startMin)}');
  }

  /// ⚡ 找空档：把课表 + 已排块当 busy、不可排时段当 rest
  void _findSlot() {
    final todo = _todoOf(_selectedTodoId);
    if (todo == null) return;
    final day = _day;
    final busy = <List<int>>[
      for (final s in _sessionsOn(day)) [s.startMin, s.endMin],
      for (final b in _blocksOn(day)) [b.startMin, b.endMin],
    ];
    final rest = <List<int>>[
      for (final w in _restRanges()) [w[0], w[1]],
    ];
    final now = widget.now();
    final isToday = formatDate(day) == formatDate(now);
    final from = isToday ? (now.hour * 60 + now.minute) : _axis.startMin;
    final slot = findFreeSlot(_axis, busy, rest, todo.estimateMin, from);
    if (slot < 0) {
      _showHint('这天（或剩余时间）排不下了，换一天试试');
      return;
    }
    _place(day, slot, todo.estimateMin);
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final days = _days;
    // 日期条是**悬浮浮窗**（鸿蒙端 DayBarFloat）：内容从它下面滑过，所以滚动区顶部留
    // 页头 + 日期条的空；底部留导航栏 + 待安排托盘的空。
    final dayBarBlock = widget.topInset + _dayBarH;
    final trayBlock = tabBarInset + (_trayOpen ? 176 : 62);
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            controller: _scroll,
            // 拖块期间锁住滚动：不锁的话外层滚动视图会抢走竖直拖动，
            // 变成"网格整体滚走、块只挪一点点"（dragOffsetWithScroll 的补偿会抵消掉大半）。
            // 贴边自动滚动由 _updateDrag 自己 jumpTo，所以锁住不影响那个功能。
            physics: _dragId != 0
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(10, dayBarBlock, 10, trayBlock),
            child: Column(
              children: [
                if (days.length > 1) _DayTitles(days: days, axisW: _axisW),
                _Grid(
                  key: _gridKey,
                  axis: _axis,
                  axisW: _axisW,
                  days: days,
                  sessions: {
                    for (final d in days) formatDate(d): _sessionsOn(d)
                  },
                  blocks: {for (final d in days) formatDate(d): _blocksOn(d)},
                  ddls: {for (final d in days) formatDate(d): _ddlOn(d)},
                  rests: {for (final d in days) formatDate(d): _restsOn(d)},
                  todoOf: _todoOf,
                  onTapMinute: (day, min) {
                    if (_selectedTodoId > 0 || _selectedLessonId > 0) {
                      final todo = _todoOf(_selectedTodoId);
                      // 课时默认 90 分钟，待办用自己的预计耗时
                      _place(day, min, todo?.estimateMin ?? 90);
                      return;
                    }
                    if (_selectedBlockId > 0) {
                      setState(() => _selectedBlockId = 0);
                      _showHint('');
                      return;
                    }
                    _showHint('单击块选中它；再点一下打开详情。长按选中的块可以拖时间。');
                  },
                  onTapBlock: _onBlockTap,
                  onToggleDone: _toggleBlockDone,
                  selectedBlockId: _selectedBlockId,
                  courseLabelOf: (id) {
                    final c = widget.bundle.courses
                        .where((x) => x.id == id)
                        .firstOrNull;
                    return c == null
                        ? ''
                        : (c.shortName.isNotEmpty ? c.shortName : c.name);
                  },
                  dragId: _dragId,
                  dragResize: _dragResize,
                  dragDeltaMin: _dragDeltaMin,
                  onDragStart: _startDrag,
                  onDragUpdate: _updateDrag,
                  onDragEnd: _endDrag,
                  onPointer: _onBlockPointer,
                  lessonTitles: {
                    for (final l in widget.bundle.lessons)
                      l.id: '第 ${l.seq} 讲 · ${l.title}',
                  },
                  lessonColors: {
                    for (final l in widget.bundle.lessons)
                      l.id: courseColor((widget.bundle.courses
                              .where((c) => c.id == l.courseId)
                              .firstOrNull
                              ?.colorIndex) ??
                          7),
                  },
                  pinchId: _pinchId,
                  pinchEndMin: _pinchEndMin,
                ),
              ],
            ),
          ),
        ),
        // 日期条：叠在悬浮页头下面
        Positioned(
          left: 0,
          right: 0,
          top: widget.topInset,
          child: MeasureSize(
            onSize: (size) {
              if ((size.height - _dayBarH).abs() > 0.5) {
                setState(() => _dayBarH = size.height);
              }
            },
            child: _DayBar(
              day: _day,
              threeDay: _threeDay,
              onPrev: () => _shift(_threeDay ? -3 : -1),
              onNext: () => _shift(_threeDay ? 3 : 1),
              onToday: _jumpToday,
              onDay: () => setState(() {
                _threeDay = false;
                _selectedBlockId = 0;
              }),
              onThreeDay: () => setState(() {
                _threeDay = true;
                _selectedBlockId = 0;
              }),
            ),
          ),
        ),
        // 待安排托盘：浮在导航栏之上
        Positioned(
          left: 0,
          right: 0,
          bottom: tabBarInset,
          child: _Tray(
            pool: _pool,
            lessons: _lessonPool,
            selectedLessonId: _selectedLessonId,
            courses: {for (final c in widget.bundle.courses) c.id: c},
            selectedId: _selectedTodoId,
            open: _trayOpen,
            onToggle: () => setState(() => _trayOpen = !_trayOpen),
            onSelect: (id) {
              setState(() {
                _selectedTodoId = _selectedTodoId == id ? 0 : id;
                _selectedLessonId = 0;
              });
              _showHint(_selectedTodoId > 0 ? '现在点网格空白处放下它' : '');
            },
            onSelectLesson: (id) {
              setState(() {
                _selectedLessonId = _selectedLessonId == id ? 0 : id;
                _selectedTodoId = 0;
              });
              _showHint(_selectedLessonId > 0 ? '现在点网格空白处放下它' : '');
            },
            onPlace: _placeFromPool,
            onPlaceLesson: _findSlotForLesson,
          ),
        ),
        // 瞬时提示：悬浮在网格上方，不参与布局（鸿蒙端 showHint 的深色小胶囊）
        if (_hint.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            top: widget.topInset + _dayBarH + 8,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xDB0C121C), // rgba(12,18,28,0.86)
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(_hint,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 托盘卡片上的「⚡ 找空档」：先选中它，再走和工具栏一样的那条路径
  void _placeFromPool(Todo t) {
    setState(() => _selectedTodoId = t.id);
    _findSlot();
  }

  /// 网格里轻点一块：未选中 → 选中；已选中 → 打开属性面板（鸿蒙 `tapAction`）
  void _onBlockTap(PlanBlock b) {
    if (_selectedBlockId == b.id) {
      _showBlockSheet(b);
      return;
    }
    setState(() {
      _selectedBlockId = b.id;
      _selectedTodoId = 0; // 选中块时清掉托盘选择，避免"两种选中"打架
      _selectedLessonId = 0;
    });
    _showHint('');
  }

  /// 块上的 ○ / ● ：直接勾完成/取消（鸿蒙 `onBlockToggleDone`）
  void _toggleBlockDone(PlanBlock b) {
    final next = !b.done;
    final blocks = widget.bundle.blocks
        .map((x) => x.id == b.id
            ? PlanBlock(
                id: x.id,
                todoId: x.todoId,
                lessonId: x.lessonId,
                date: x.date,
                startMin: x.startMin,
                endMin: x.endMin,
                done: next,
              )
            : x)
        .toList();
    final lessons = b.lessonId > 0
        ? widget.bundle.lessons
            .map((l) => l.id == b.lessonId
                ? VirtualLesson(
                    id: l.id,
                    courseId: l.courseId,
                    seq: l.seq,
                    title: l.title,
                    done: next,
                    doneAt:
                        next ? DateTime.now().millisecondsSinceEpoch : 0,
                  )
                : l)
            .toList()
        : widget.bundle.lessons;
    widget.onChanged(BackupBundle(
      app: widget.bundle.app,
      version: widget.bundle.version,
      exportedAt: widget.bundle.exportedAt,
      semesters: widget.bundle.semesters,
      sectionTimes: widget.bundle.sectionTimes,
      courses: widget.bundle.courses,
      rules: widget.bundle.rules,
      overrides: widget.bundle.overrides,
      todos: widget.bundle.todos,
      blocks: blocks,
      restWindows: widget.bundle.restWindows,
      templates: widget.bundle.templates,
      lessons: lessons,
    ));
  }

  /// 虚拟课时的一讲（鸿蒙端 autoPlaceLesson）：固定 90 分钟，从"现在"往后找。
  void _findSlotForLesson(VirtualLesson l) {
    final day = _day;
    final busy = <List<int>>[
      for (final s in _sessionsOn(day)) [s.startMin, s.endMin],
      for (final b in _blocksOn(day)) [b.startMin, b.endMin],
    ];
    final rest = <List<int>>[
      for (final w in _restRanges()) [w[0], w[1]],
    ];
    final now = widget.now();
    final isToday = formatDate(day) == formatDate(now);
    final from = isToday ? (now.hour * 60 + now.minute) : _axis.startMin;
    final slot = findFreeSlot(_axis, busy, rest, 90, from);
    if (slot < 0) {
      _showHint('这天（或剩余时间）排不下了，换一天试试');
      return;
    }
    setState(() => _selectedLessonId = l.id);
    _place(day, slot, 90);
  }

  /// 原始指针：两指时按间距比例缩放当前块；单指/抬指时结束
  void _onBlockPointer(
      PlanBlock block, int pointer, Offset position, bool down) {
    // 双指缩放只对**选中的那一块**生效（鸿蒙 beginPinch 的守卫）
    if (block.id != _selectedBlockId) return;
    final before = _pointers.length;
    if (down) {
      _pointers[pointer] = position;
    } else {
      _pointers.remove(pointer);
    }
    final two = _pointers.length >= 2;
    if (two && before < 2) {
      // 第二根手指按下：以当前两指间距为基准
      final pts = _pointers.values.take(2).toList();
      _pinchBaseDist = (pts[0] - pts[1]).distance;
      _pinchStart(block);
    } else if (two && _pinchId != 0) {
      final pts = _pointers.values.take(2).toList();
      final d = (pts[0] - pts[1]).distance;
      // 用当前这个块的原始时长做基准（_pinchUpdate 里算比例）
      if (_pinchBaseDist > 1) {
        final b = widget.bundle.blocks
            .firstWhere((x) => x.id == _pinchId, orElse: () => block);
        _pinchUpdate(b, d / _pinchBaseDist);
      }
    } else if (!two && before >= 2 && _pinchId != 0) {
      final b = widget.bundle.blocks
          .firstWhere((x) => x.id == _pinchId, orElse: () => PlanBlock(id: 0));
      if (b.id != 0) _pinchEnd(b);
      _pinchBaseDist = 0;
    }
  }

  // ---- 双指缩放改时长（鸿蒙端 PinchGesture：块高随时长变） ----
  void _pinchStart(PlanBlock b) {
    setState(() {
      _pinchId = b.id;
      _pinchEndMin = b.endMin;
    });
  }

  void _pinchUpdate(PlanBlock b, double scale) {
    if (_pinchId != b.id) return;
    final base = b.endMin - b.startMin;
    final dur = (base * scale).round().clamp(15, _axis.endMin - b.startMin);
    setState(() => _pinchEndMin = b.startMin + dur);
  }

  void _pinchEnd(PlanBlock b) {
    final end = _pinchEndMin;
    final id = _pinchId;
    setState(() {
      _pinchId = 0;
      _pinchEndMin = 0;
    });
    if (id == 0 || end == 0 || end == b.endMin) return;
    widget.onChanged(_withBlocks(widget.bundle.blocks
        .map((x) => x.id == b.id
            ? PlanBlock(
                id: x.id,
                todoId: x.todoId,
                lessonId: x.lessonId,
                date: x.date,
                startMin: x.startMin,
                endMin: end,
                done: x.done)
            : x)
        .toList()));
  }

  Future<void> _showBlockSheet(PlanBlock b) => showBlockEditor(
        context,
        bundle: widget.bundle,
        block: b,
        window: TimeWindow(_axis.startMin, _axis.endMin),
        onChanged: widget.onChanged,
        onNotePref: widget.onNotePref,
      );
}

// ---------------- 页头 ----------------

/// 计划页的日期条 —— 鸿蒙端 `PlanDayView.ets → DayBarFloat()`：
///   ‹  10 月 16 日 周五 / 今天  ›    [日] [三日]   今天
class _DayBar extends StatelessWidget {
  final DateTime day;
  final bool threeDay;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onDay;
  final VoidCallback onThreeDay;

  const _DayBar({
    required this.day,
    required this.threeDay,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onDay,
    required this.onThreeDay,
  });

  @override
  Widget build(BuildContext context) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = names[weekdayOf(day) - 1];
    return Glass(
      sheet: true,
      margin: const EdgeInsets.fromLTRB(floatSide, 4, floatSide, 4),
      // 鸿蒙 DayBarFloat：padding 左 8 / 右 12 / 上 10 / 下 8
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
      child: Row(
        children: [
          _BarTap(
            onTap: onPrev,
            child: const Icon(Icons.chevron_left, size: 26, color: accentBlue),
          ),
          Expanded(
            child: Column(
              children: [
                // 窄屏放不下时等比缩小，不折行（鸿蒙端一行放得下）
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('${day.month} 月 ${day.day} 日 周$wd',
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                ),
                Text(relativeDayText(day, today()),
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF94A0B5))),
              ],
            ),
          ),
          _BarTap(
            onTap: onNext,
            child: const Icon(Icons.chevron_right, size: 26, color: accentBlue),
          ),
          const SizedBox(width: 6),
          _Chip(text: '日', selected: !threeDay, onTap: onDay),
          _Chip(text: '三日', selected: threeDay, onTap: onThreeDay),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onToday,
            behavior: HitTestBehavior.opaque,
            child: const Text('今天',
                style: TextStyle(fontSize: 14, color: accentBlue)),
          ),
        ],
      ),
    );
  }
}

class _BarTap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _BarTap({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: child,
      ),
    );
  }
}

/// 可选中的小胶囊（鸿蒙端 ChipButton：选中 = 蓝底白字）
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
        margin: const EdgeInsets.only(right: 6),
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

class _DayTitles extends StatelessWidget {
  final List<DateTime> days;
  final double axisW;
  const _DayTitles({required this.days, required this.axisW});

  @override
  Widget build(BuildContext context) {
    final now = formatDate(today());
    // 鸿蒙 ColHeadRow：玻璃条 + 轴宽占位 + 三列等分；**中间那列**是当前查看日的高亮
    final center = days.length ~/ 2;
    return Glass(
      radius: 0,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: gridPad),
        child: Row(
          children: [
            SizedBox(width: axisW, height: colHeadH),
            for (var i = 0; i < days.length; i++)
              Expanded(
                child: Container(
                  height: colHeadH,
                  color: i == center
                      ? const Color(0x1AFFFFFF) // rgba(255,255,255,0.10)
                      : const Color(0x08FFFFFF), // rgba(255,255,255,0.03)
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 三列时列宽只有 ~105vp：等比缩小，绝不折行（折行会撑破 34 高）
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                            '${days[i].month}/${days[i].day} '
                            '周${weekdayCn[weekdayOf(days[i]) - 1]}',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                                fontSize: 14,
                                height: 1.1,
                                fontWeight: i == center
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                                color: i == center
                                    ? inkPrimary
                                    : const Color(0xFFA9B5C9))),
                      ),
                      if (formatDate(days[i]) == now)
                        const Text('今天',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.1,
                                color: Color(0xFF7FA8FF))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 网格 ----------------

class _Grid extends StatelessWidget {
  final TimeAxis axis;
  final double axisW;
  final List<DateTime> days;
  final Map<String, List<CourseSession>> sessions;
  final Map<String, List<PlanBlock>> blocks;
  final Map<String, List<DdlGroup>> ddls;

  /// 每天各自的不可排时段（已按星日过滤 + 裁到时间窗内）
  final Map<String, List<RestWindow>> rests;
  final Todo? Function(int) todoOf;
  final void Function(DateTime, int) onTapMinute;
  final void Function(PlanBlock) onTapBlock;
  final void Function(PlanBlock) onToggleDone;

  /// 选中的块 id（两步模型的"选中态"：2px 白框）
  final int selectedBlockId;

  /// 课程 id → 简称（块的副文字/紧凑标题用）
  final String Function(int) courseLabelOf;

  // 拖动 / 缩放
  final int dragId;
  final bool dragResize;
  final int dragDeltaMin;
  final void Function(PlanBlock, bool resize, Offset pos) onDragStart;
  final void Function(Offset pos) onDragUpdate;
  final VoidCallback onDragEnd;
  final void Function(PlanBlock b, int pointer, Offset position, bool down)
      onPointer;

  /// 课时 id → 标题 / 课程色（渲染虚拟课时的块用）
  final Map<int, String> lessonTitles;
  final Map<int, Color> lessonColors;
  final int pinchId;
  final int pinchEndMin;

  const _Grid({
    super.key,
    required this.axis,
    required this.axisW,
    required this.days,
    required this.sessions,
    required this.blocks,
    required this.ddls,
    required this.rests,
    required this.todoOf,
    required this.onTapMinute,
    required this.onTapBlock,
    required this.onToggleDone,
    required this.selectedBlockId,
    required this.courseLabelOf,
    required this.dragId,
    required this.dragResize,
    required this.dragDeltaMin,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onPointer,
    required this.lessonTitles,
    required this.lessonColors,
    required this.pinchId,
    required this.pinchEndMin,
  });

  @override
  Widget build(BuildContext context) {
    final h = axis.height();
    // ⚠️ 必须是**透明**的（对照鸿蒙端真机：网格底下是壁纸，只有细横线）：
    // 之前套了一层 Glass，壁纸被灰白面板盖住，双机对比时一眼就看出来。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        height: h + 12,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: axisW,
              child: Stack(
                children: [
                  for (final m in axis.marks)
                    Positioned(
                      top: (m - axis.startMin).toDouble(),
                      right: 4,
                      child: Text(minToHHmm(m),
                          // 鸿蒙端 LAYOUT.hour=12、颜色 #CBD6E8（时间刻度是最不能含糊的）
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFCBD6E8))),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: _DayColumn(
                        key: ValueKey('plan-day-${formatDate(d)}'),
                        axis: axis,
                        dragId: dragId,
                        dragResize: dragResize,
                        dragDeltaMin: dragDeltaMin,
                        onDragStart: onDragStart,
                        onDragUpdate: onDragUpdate,
                        onDragEnd: onDragEnd,
                        onPointer: onPointer,
                        lessonTitles: lessonTitles,
                        lessonColors: lessonColors,
                        pinchId: pinchId,
                        pinchEndMin: pinchEndMin,
                        day: d,
                        sessions: sessions[formatDate(d)] ?? const [],
                        blocks: blocks[formatDate(d)] ?? const [],
                        ddls: ddls[formatDate(d)] ?? const [],
                        rests: rests[formatDate(d)] ?? const [],
                        singleDay: days.length == 1,
                        todoOf: todoOf,
                        onTapMinute: onTapMinute,
                        onTapBlock: onTapBlock,
                        onToggleDone: onToggleDone,
                        selectedBlockId: selectedBlockId,
                        courseLabelOf: courseLabelOf,
                      ),
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

class _DayColumn extends StatelessWidget {
  final TimeAxis axis;
  final int dragId;
  final bool dragResize;
  final int dragDeltaMin;
  final void Function(PlanBlock, bool resize, Offset pos) onDragStart;
  final void Function(Offset pos) onDragUpdate;
  final VoidCallback onDragEnd;
  final void Function(PlanBlock b, int pointer, Offset position, bool down)
      onPointer;
  final Map<int, String> lessonTitles;
  final Map<int, Color> lessonColors;
  final int pinchId;
  final int pinchEndMin;
  final DateTime day;
  final List<CourseSession> sessions;
  final List<PlanBlock> blocks;
  final List<DdlGroup> ddls;
  final List<RestWindow> rests;
  final bool singleDay;
  final Todo? Function(int) todoOf;
  final void Function(DateTime, int) onTapMinute;
  final void Function(PlanBlock) onTapBlock;
  final void Function(PlanBlock) onToggleDone;
  final int selectedBlockId;
  final String Function(int) courseLabelOf;

  const _DayColumn({
    super.key,
    required this.axis,
    required this.dragId,
    required this.dragResize,
    required this.dragDeltaMin,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onPointer,
    required this.lessonTitles,
    required this.lessonColors,
    required this.pinchId,
    required this.pinchEndMin,
    required this.day,
    required this.sessions,
    required this.blocks,
    required this.ddls,
    required this.rests,
    required this.singleDay,
    required this.todoOf,
    required this.onTapMinute,
    required this.onTapBlock,
    required this.onToggleDone,
    required this.selectedBlockId,
    required this.courseLabelOf,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final min = axis.startMin + details.localPosition.dy.round();
        onTapMinute(day, snap(min));
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border(
              left: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
        ),
        child: Stack(
          children: [
            // 不可排时段（"睡觉""午休"）：斜纹淡标记，压在最下面
            for (final w in rests)
              _RestBand(
                top: (w.startMin - axis.startMin).toDouble(),
                height: (w.endMin - w.startMin).toDouble(),
                label: w.label,
                showLabel: singleDay && (w.endMin - w.startMin) >= 46,
              ),
            // 整点横线
            for (final m in axis.marks)
              Positioned(
                top: (m - axis.startMin).toDouble(),
                left: 0,
                right: 0,
                child: Container(
                    height: 1, color: Colors.white.withValues(alpha: 0.12)),
              ),
            // 课表灰带（鸿蒙端 ClassBlock：白 0.10 + 左对齐 12/11 号字）
            for (final s in sessions)
              _Band(
                top: (s.startMin - axis.startMin).toDouble(),
                height: (s.endMin - s.startMin).toDouble(),
                course: s.course,
                location: s.location,
              ),
            // 计划块
            for (final b in blocks)
              _Block(
                block: b,
                axis: axis,
                todo: todoOf(b.todoId),
                dragging: dragId == b.id,
                resizing: dragId == b.id && dragResize,
                dragDeltaMin: dragId == b.id ? dragDeltaMin : 0,
                onTap: () => onTapBlock(b),
                onToggleDone: () => onToggleDone(b),
                onDragStart: onDragStart,
                onDragUpdate: onDragUpdate,
                onDragEnd: onDragEnd,
                onPointer: onPointer,
                lessonTitle: lessonTitles[b.lessonId],
                lessonColor: lessonColors[b.lessonId],
                pinchEndMin: pinchId == b.id ? pinchEndMin : 0,
                selected: selectedBlockId == b.id,
                courseLabel: courseLabelOf(todoOf(b.todoId)?.courseId ?? 0),
              ),
            // 截止标记
            for (final g in ddls)
              _DdlMark(
                top: (g.minute - axis.startMin).toDouble(),
                label: g.todos.length > 1
                    ? '⚑ ${g.todos.length} 项截止'
                    : '⚑ ${g.todos.first.title} 截止',
                onTap: () => _showDdlList(context, g),
              ),
          ],
        ),
      ),
    );
  }
}

class _Band extends StatelessWidget {
  final double top;
  final double height;
  final Course course;
  final String location;
  const _Band({
    required this.top,
    required this.height,
    required this.course,
    required this.location,
  });

  @override
  Widget build(BuildContext context) {
    final short = course.shortName.isNotEmpty ? course.shortName : course.name;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: height - 2,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        // 鸿蒙 ClassBlock 的 Column 没设对齐 → 默认居中（真机图上课程灰带就是居中）
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFFA9B5C9))),
            if (height > 40 && location.isNotEmpty)
              Text(location,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF8B97AC))),
          ],
        ),
      ),
    );
  }
}

/// 不可排时段：45° 斜纹（鸿蒙端 RestBands）
class _RestBand extends StatelessWidget {
  final double top;
  final double height;
  final String label;
  final bool showLabel;
  const _RestBand({
    required this.top,
    required this.height,
    required this.label,
    required this.showLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _StripePainter(),
          child: Align(
            alignment: Alignment.topRight,
            child: showLabel
                ? Padding(
                    padding: const EdgeInsets.only(right: 6, top: 3),
                    child: Text(label,
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 9, color: Color(0xFF7C8798))),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 45° 斜纹 + 圆角细边（decorative only）
class _StripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0x0E7FA8FF));
    final paint = Paint()
      ..color = const Color(0x0DFFFFFF)
      ..strokeWidth = 3;
    for (var x = -size.height; x < size.width + size.height; x += 12) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
    canvas.restore();
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x12FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_StripePainter old) => false;
}

class _Block extends StatelessWidget {
  final PlanBlock block;
  final TimeAxis axis;
  final Todo? todo;
  final bool dragging;
  final bool resizing;
  final int dragDeltaMin;

  /// 虚拟课时的标题/课程色（todoId=0 且 lessonId>0 时用）
  final String? lessonTitle;
  final Color? lessonColor;

  /// 双指缩放预览的结束分钟（0 = 没在缩这个块）
  final int pinchEndMin;

  /// 是否选中（选中 = 2px 白框）
  final bool selected;

  /// 所属课程简称（副文字 / 紧凑标题用；空 = 没课程）
  final String courseLabel;
  final void Function(PlanBlock b, int pointer, Offset position, bool down)
      onPointer;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;
  final void Function(PlanBlock, bool resize, Offset pos) onDragStart;
  final void Function(Offset pos) onDragUpdate;
  final VoidCallback onDragEnd;

  const _Block({
    required this.block,
    required this.axis,
    required this.todo,
    required this.dragging,
    required this.resizing,
    required this.dragDeltaMin,
    this.lessonTitle,
    this.lessonColor,
    required this.pinchEndMin,
    required this.selected,
    required this.courseLabel,
    required this.onPointer,
    required this.onTap,
    required this.onToggleDone,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  /// 紧凑排版阈值（鸿蒙 `compactThreshold()` = ceil(14*1.35)+ceil(11*1.35) = 34）
  static const double compactThreshold = 34;

  /// 块在屏幕上的高度（鸿蒙 `blockH`：时长 - 2，再夹到最小可见高/紧凑最小高）
  double get _paintedH {
    final endMin = pinchEndMin > 0
        ? pinchEndMin
        : (resizing ? block.endMin : block.endMin + dragDeltaMin);
    final startMin = resizing ? block.startMin : block.startMin + dragDeltaMin;
    final timed = (endMin - startMin).toDouble() - 2;
    if (timed < 6) return 6;
    if (timed < compactThreshold) return 14;
    return timed;
  }

  /// 副文字（鸿蒙 `blockSubText`）：12:00-12:15 · 高数
  String get _subText {
    final endMin = pinchEndMin > 0 ? pinchEndMin : block.endMin;
    final t = '${minToHHmm(block.startMin)}-${minToHHmm(endMin)}';
    return courseLabel.isEmpty ? t : '$t · $courseLabel';
  }

  /// 紧凑标题（鸿蒙 `blockCompactTitle`）：课程简称·标题
  String get _compactTitle {
    final title = todo?.title ?? (lessonTitle ?? '计划块');
    return courseLabel.isEmpty ? title : '$courseLabel·$title';
  }

  @override
  Widget build(BuildContext context) {
    final color = todo != null
        ? courseColor(todo!.courseId)
        : (lessonColor ?? const Color(0xFF4A5B75));
    final topMin = resizing ? block.startMin : block.startMin + dragDeltaMin;
    final top = (topMin - axis.startMin).toDouble();
    final h = _paintedH;
    final compact = h < compactThreshold;
    final opacity = dragging ? 0.72 : (block.done ? 0.5 : 0.95);
    final showBorder = selected || dragging;

    final content = compact
        // 紧凑排版：单行「课程简称·标题 + 开始时间」，不画完成圆圈
        ? Container(
            width: double.infinity,
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 5)
                .copyWith(left: 7),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(_compactTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary,
                          decoration: block.done
                              ? TextDecoration.lineThrough
                              : null)),
                ),
                const SizedBox(width: 6),
                Text(minToHHmm(block.startMin),
                    style: const TextStyle(
                        fontSize: 9, color: Color(0xFFCBD6E8))),
              ],
            ),
          )
        // 常规排版：○ / ● + 标题（两行） + 时间·课程（一行）
        : Container(
            width: double.infinity,
            height: double.infinity,
            padding: const EdgeInsets.fromLTRB(8, 3, 6, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: onToggleDone,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(block.done ? '●' : '○',
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.1,
                            color: block.done
                                ? const Color(0xFF7FA8FF)
                                : Colors.white)),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(todo?.title ?? (lessonTitle ?? '计划块'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              color: inkPrimary,
                              decoration: block.done
                                  ? TextDecoration.lineThrough
                                  : null)),
                      Text(_subText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFCBD6E8))),
                    ],
                  ),
                ),
              ],
            ),
          );

    return Positioned(
      top: top,
      left: 3,
      right: 3,
      height: h,
      // 两步模型（鸿蒙端：先选中、再长按拖）：
      //   轻点 = 选中（再点 = 打开属性面板）；**长按 400ms** 才开始拖动。
      // 用 GestureDetector 的 longPress 而不是 Listener：长按会赢手势竞技场，
      // 轻滑（想滚时间轴）时长按被系统 cancel，Scroll 照常接管 —— 和鸿蒙端
      // `parallelGesture(LongPress)` 的效果一致。
      child: Listener(
        onPointerDown: (e) => onPointer(block, e.pointer, e.position, true),
        onPointerMove: (e) => onPointer(block, e.pointer, e.position, true),
        onPointerUp: (e) => onPointer(block, e.pointer, e.position, false),
        onPointerCancel: (e) => onPointer(block, e.pointer, e.position, false),
        child: GestureDetector(
          onTap: onTap,
          onLongPressStart: (e) {
            final box = context.findRenderObject() as RenderBox?;
            final bh = box?.size.height ?? 0;
            // 按在底部 18vp 内 = 拖底边改时长，否则整块平移
            onDragStart(
                block, e.localPosition.dy > bh - 18, e.globalPosition);
          },
          onLongPressMoveUpdate: (e) => onDragUpdate(e.globalPosition),
          onLongPressEnd: (_) => onDragEnd(),
          onLongPressCancel: onDragEnd,
          child: Opacity(
            key: ValueKey('plan-block-${block.id}'),
            opacity: opacity,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
                border: showBorder
                    ? Border.all(color: const Color(0xFFF2F5FA), width: 2)
                    : null,
              ),
              clipBehavior: Clip.hardEdge,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _DdlMark extends StatelessWidget {
  final double top;
  final String label;
  final VoidCallback onTap;
  const _DdlMark({required this.top, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 1,
      right: 1,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 1, 4, 1),
          decoration: BoxDecoration(
            color: const Color(0x2ED64545), // rgba(214,69,69,0.18)
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 鸿蒙 LAYOUT.tray = 14
              style: const TextStyle(fontSize: 14, color: Color(0xFFFF8A8A))),
        ),
      ),
    );
  }
}

/// 截止标记的展开列表（鸿蒙端是 bindPopup 浮层；这里用深色弹窗，效果一致）
Future<void> _showDdlList(BuildContext context, DdlGroup g) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xE60C101A),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(glassRadius)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${minToHHmm(g.minute)} 截止 · ${g.todos.length} 项',
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A8A))),
            const SizedBox(height: 6),
            for (final t in g.todos)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 14, color: inkPrimary)),
                    ),
                    Text(ddlText(t.ddl),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF9BA7BD))),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                style: TextButton.styleFrom(foregroundColor: accentBlue),
                child: const Text('知道了', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------------- 待安排托盘 ----------------

/// 待安排托盘 —— 鸿蒙端 `TraySummonBar`（收起）↔ `TodoPool`（展开）。
///
/// 收起时只有一条玻璃货架：「待安排 N  展开 ▴」；点开后变成横向卡片列表：
///   标题 / 课程胶囊 / 预计 N 分钟 / ⚡ 找空档，选中 = 半透明蓝 + 亮蓝描边。
class _Tray extends StatelessWidget {
  final List<Todo> pool;

  /// 虚拟课程的课时（待排）
  final List<VirtualLesson> lessons;
  final Map<int, Course> courses;
  final int selectedId;
  final int selectedLessonId;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onSelectLesson;
  final void Function(Todo t) onPlace;
  final void Function(VirtualLesson l) onPlaceLesson;

  const _Tray({
    required this.pool,
    required this.lessons,
    required this.courses,
    required this.selectedId,
    required this.selectedLessonId,
    required this.open,
    required this.onToggle,
    required this.onSelect,
    required this.onSelectLesson,
    required this.onPlace,
    required this.onPlaceLesson,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(floatSide, 0, floatSide, floatGap),
      child: GlassShelf(
        padding: EdgeInsets.zero,
        child: open ? _expanded(context) : _collapsed(),
      ),
    );
  }

  Widget _collapsed() {
    return GestureDetector(
      key: const ValueKey('tray-toggle'),
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            const Text('待安排',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: inkPrimary)),
            const SizedBox(width: 6),
            Text('${pool.length + lessons.length}',
                style: const TextStyle(fontSize: 12, color: accentBlue)),
            const Spacer(),
            const Text('展开 ▴',
                style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
          ],
        ),
      ),
    );
  }

  /// 展开后的货架（鸿蒙端 TodoPool）：标题行 + 待办横排 + （有虚拟课时才有的）课时横排
  Widget _expanded(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey('tray-toggle'),
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Text('待安排',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const Spacer(),
                Text(
                    selectedId > 0
                        ? '已选中，点网格空白处放下'
                        : '拖动 / 点选 / ⚡ 一键找空档',
                    style: TextStyle(
                        fontSize: 12,
                        color: selectedId > 0
                            ? accentBlue
                            : const Color(0xFF8B97AC))),
                const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Text('收起 ▾',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
                ),
              ],
            ),
          ),
        ),
        if (pool.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text('没有待安排的事项。先去『待办』里确认几条。',
                style: TextStyle(fontSize: 14, color: Color(0xFF8B97AC))),
          )
        else
          _strip([for (final t in pool) _poolCard(t)]),
        if (lessons.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Text('虚拟课程课时（拖进计划，打勾完成会触发生成待办）',
                style: TextStyle(fontSize: 12, color: Color(0xFFE0A94E))),
          ),
          _strip([for (final l in lessons) _lessonCard(l)]),
        ],
        const SizedBox(height: 10),
      ],
    );
  }

  /// 横向卡片条：卡片宽 140，间隔 8，左右 12（鸿蒙端 `Scroll` + `Row`）
  Widget _strip(List<Widget> cards) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            cards[i],
          ],
        ],
      ),
    );
  }

  /// 课时卡片上的标题（鸿蒙端 `lessonTitle`）：没起名就「课程简称 第 N 讲」
  String _lessonTitle(VirtualLesson l) {
    if (l.title.isNotEmpty) return l.title;
    final c = courses[l.courseId];
    final name = c == null
        ? '虚拟课程'
        : (c.shortName.isNotEmpty ? c.shortName : c.name);
    return '$name 第 ${l.seq} 讲';
  }

  /// 小卡（鸿蒙端 glassCard）：半透明纯色 + 细边 + 投影，不使用模糊
  BoxDecoration _cardDecoration({required bool selected, Color? tint, Color? edge}) {
    return BoxDecoration(
      color: selected ? const Color(0x4D2E6BE6) : (tint ?? glassTintRow),
      borderRadius: BorderRadius.circular(glassRadius),
      border: Border.all(
          width: selected ? 1.5 : 1,
          color: selected ? accentBlue : (edge ?? glassEdgeSoft)),
      boxShadow: glassShadowRow,
    );
  }

  /// 虚拟课时卡片：暖色薄纱，和真待办的小卡一眼能分开（鸿蒙端同款）
  Widget _lessonCard(VirtualLesson l) {
    final selected = l.id == selectedLessonId;
    return GestureDetector(
      key: ValueKey('pool-lesson-${l.id}'),
      onTap: () => onSelectLesson(l.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(10),
        decoration: _cardDecoration(
          selected: selected,
          tint: const Color(0x29F0BE5A), // rgba(240,190,90,0.16)
          edge: const Color(0x47F0BE5A), // rgba(240,190,90,0.28)
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_lessonTitle(l),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: inkPrimary)),
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('90 分钟',
                  style: TextStyle(fontSize: 12, color: Color(0xFFD8C48A))),
            ),
            GestureDetector(
              key: ValueKey('pool-lesson-find-${l.id}'),
              onTap: () => onPlaceLesson(l),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('⚡ 找空档',
                    style: TextStyle(fontSize: 12, color: Color(0xFFE8B25C))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _poolCard(Todo t) {
    final selected = t.id == selectedId;
    final course = courses[t.courseId];
    return GestureDetector(
      key: ValueKey('pool-${t.id}'),
      onTap: () => onSelect(t.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(10),
        decoration: _cardDecoration(selected: selected),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: inkPrimary)),
            if (course != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: courseColor(course.colorIndex),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(course.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFEAF0FA))),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('预计 ${t.estimateMin} 分钟',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9BA7BD))),
            ),
            GestureDetector(
              key: ValueKey('pool-find-${t.id}'),
              onTap: () => onPlace(t),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('⚡ 找空档',
                    style: TextStyle(fontSize: 12, color: Color(0xFF7FA8FF))),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
