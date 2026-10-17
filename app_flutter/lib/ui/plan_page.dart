// 计划页（第一版）：日/三日时间轴 + 课表灰带 + 计划块 + 截止标记 + 待安排托盘。
//
// 几何完全沿用 PlanMath：1 分钟 = 1vp，时间窗默认 07:00–24:00，吸附 15 分钟。
// 还没做的：拖动/缩放（PlanMath 的 dropRange/moveRange/resizeRange 已移植并有 fixtures，
// 等交互打磨时接上）、属性面板里的改时间、三日视图的横向拖拽。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/todo_list.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'palette.dart';

class PlanPage extends StatefulWidget {
  final BackupBundle bundle;
  final void Function(BackupBundle next) onChanged;

  /// 计划页画哪一段（设置页可改）
  final TimeWindow window;

  /// 不可排时段：优先用库里的，空则用默认值
  final List<RestWindow> restWindows;

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

  /// 待安排托盘是否展开（鸿蒙端 TraySummonBar ↔ TodoPool）
  bool _trayOpen = false;

  // ---- 拖动 / 缩放（见 domain/plan_math.dart 的 moveRange / resizeRange / edgeScroll*）----
  final ScrollController _scroll = ScrollController();
  final GlobalKey _gridKey = GlobalKey();

  /// 正在拖的块 id（0 = 没在拖）
  int _dragId = 0;

  /// 拖的是底边（缩放）还是整块（移动）
  bool _dragResize = false;

  /// 手指按下时的窗口 y
  double _dragTouchStartY = 0;

  /// 按下时的滚动位置
  double _dragScrollStart = 0;

  /// 预览用的偏移（分钟）：拖动过程中只改这个，松手才写数据
  int _dragDeltaMin = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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

  void _startDrag(PlanBlock b, bool resize, double globalY) {
    setState(() {
      _dragId = b.id;
      _dragResize = resize;
      _dragTouchStartY = globalY;
      _dragScrollStart = _scroll.hasClients ? _scroll.offset : 0;
      _dragDeltaMin = 0;
    });
  }

  void _updateDrag(double globalY) {
    if (_dragId == 0) return;
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
    setState(() {
      _dragId = 0;
      _dragDeltaMin = 0;
    });
    if (id == 0 || delta == 0) return;
    final b = widget.bundle.blocks.firstWhere((x) => x.id == id);
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
            date: x.date,
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
      );

  int _nextBlockId() =>
      widget.bundle.blocks.fold<int>(0, (m, b) => b.id > m ? b.id : m) + 1;

  void _place(DateTime day, int startMin, int durationMin) {
    final todo = _todoOf(_selectedTodoId);
    if (todo == null) return;
    final end = startMin + normalizeDuration(durationMin);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这一天找不到合适空档')));
      return;
    }
    _place(day, slot, todo.estimateMin);
  }

  void _removeBlock(PlanBlock b) => widget.onChanged(
      _withBlocks(widget.bundle.blocks.where((x) => x.id != b.id).toList()));

  void _halveBlock(PlanBlock b) {
    final parts = halveMinutes(b.endMin - b.startMin);
    if (parts.isEmpty) return;
    final blocks = widget.bundle.blocks.where((x) => x.id != b.id).toList()
      ..add(PlanBlock(
          id: _nextBlockId(),
          todoId: b.todoId,
          date: b.date,
          startMin: b.startMin,
          endMin: b.startMin + parts[0],
          done: b.done))
      ..add(PlanBlock(
          id: _nextBlockId() + 1,
          todoId: b.todoId,
          date: b.date,
          startMin: b.startMin + parts[0],
          endMin: b.endMin,
          done: b.done));
    widget.onChanged(_withBlocks(blocks));
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final days = _days;
    return Column(
      children: [
        _DayBar(
          day: _day,
          threeDay: _threeDay,
          onPrev: () => _shift(_threeDay ? -3 : -1),
          onNext: () => _shift(_threeDay ? 3 : 1),
          onToday: _jumpToday,
          onDay: () => setState(() => _threeDay = false),
          onThreeDay: () => setState(() => _threeDay = true),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            // 拖块期间锁住滚动：不锁的话外层滚动视图会抢走竖直拖动，
            // 变成"网格整体滚走、块只挪一点点"（dragOffsetWithScroll 的补偿会抵消掉大半）。
            // 贴边自动滚动由 _updateDrag 自己 jumpTo，所以锁住不影响那个功能。
            physics: _dragId != 0
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8 + tabBarInset),
            child: Column(
              children: [
                _DayTitles(days: days, axisW: _axisW),
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
                    if (_selectedTodoId == 0) return;
                    final todo = _todoOf(_selectedTodoId);
                    _place(day, min, todo?.estimateMin ?? 60);
                  },
                  onTapBlock: _showBlockSheet,
                  dragId: _dragId,
                  dragResize: _dragResize,
                  dragDeltaMin: _dragDeltaMin,
                  onDragStart: _startDrag,
                  onDragUpdate: _updateDrag,
                  onDragEnd: _endDrag,
                ),
              ],
            ),
          ),
        ),
        _Tray(
          pool: _pool,
          courses: {for (final c in widget.bundle.courses) c.id: c},
          selectedId: _selectedTodoId,
          open: _trayOpen,
          onToggle: () => setState(() => _trayOpen = !_trayOpen),
          onSelect: (id) =>
              setState(() => _selectedTodoId = _selectedTodoId == id ? 0 : id),
          onPlace: _placeFromPool,
        ),
      ],
    );
  }

  /// 托盘卡片上的「⚡ 找空档」：先选中它，再走和工具栏一样的那条路径
  void _placeFromPool(Todo t) {
    setState(() => _selectedTodoId = t.id);
    _findSlot();
  }

  Future<void> _showBlockSheet(PlanBlock b) async {
    final todo = _todoOf(b.todoId);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B2436),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(todo?.title ?? '这一块',
                  style: const TextStyle(fontSize: 15, color: inkPrimary)),
              subtitle: Text(
                  '${b.date} ${minToHHmm(b.startMin)}–${minToHHmm(b.endMin)}',
                  style: const TextStyle(fontSize: 12, color: inkTertiary)),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _halveBlock(b);
                    },
                    child: const Text('对半分')),
                TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _removeBlock(b);
                    },
                    child: const Text('移除此块')),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
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
      margin:
          const EdgeInsets.fromLTRB(floatSide, floatTop, floatSide, floatGap),
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
                Text('${day.month} 月 ${day.day} 日 周$wd',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                Text(relativeDayText(day, today()),
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
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final now = formatDate(today());
    return Padding(
      padding: EdgeInsets.only(left: axisW, bottom: 6),
      child: Row(
        children: [
          for (final d in days)
            Expanded(
              child: Column(
                children: [
                  Text('周${names[weekdayOf(d) - 1]}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: formatDate(d) == now
                              ? accentBlue
                              : inkSecondary)),
                  Text('${d.month}/${d.day}',
                      style: TextStyle(
                          fontSize: 10,
                          color:
                              formatDate(d) == now ? accentBlue : inkTertiary)),
                ],
              ),
            ),
        ],
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

  // 拖动 / 缩放
  final int dragId;
  final bool dragResize;
  final int dragDeltaMin;
  final void Function(PlanBlock, bool resize, double globalY) onDragStart;
  final void Function(double globalY) onDragUpdate;
  final VoidCallback onDragEnd;

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
    required this.dragId,
    required this.dragResize,
    required this.dragDeltaMin,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final h = axis.height();
    return Glass(
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
                          style:
                              const TextStyle(fontSize: 9, color: inkTertiary)),
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
                        day: d,
                        sessions: sessions[formatDate(d)] ?? const [],
                        blocks: blocks[formatDate(d)] ?? const [],
                        ddls: ddls[formatDate(d)] ?? const [],
                        rests: rests[formatDate(d)] ?? const [],
                        singleDay: days.length == 1,
                        todoOf: todoOf,
                        onTapMinute: onTapMinute,
                        onTapBlock: onTapBlock,
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
  final void Function(PlanBlock, bool resize, double globalY) onDragStart;
  final void Function(double globalY) onDragUpdate;
  final VoidCallback onDragEnd;
  final DateTime day;
  final List<CourseSession> sessions;
  final List<PlanBlock> blocks;
  final List<DdlGroup> ddls;
  final List<RestWindow> rests;
  final bool singleDay;
  final Todo? Function(int) todoOf;
  final void Function(DateTime, int) onTapMinute;
  final void Function(PlanBlock) onTapBlock;

  const _DayColumn({
    super.key,
    required this.axis,
    required this.dragId,
    required this.dragResize,
    required this.dragDeltaMin,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.day,
    required this.sessions,
    required this.blocks,
    required this.ddls,
    required this.rests,
    required this.singleDay,
    required this.todoOf,
    required this.onTapMinute,
    required this.onTapBlock,
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
                    height: 1, color: Colors.white.withValues(alpha: 0.05)),
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
                onDragStart: onDragStart,
                onDragUpdate: onDragUpdate,
                onDragEnd: onDragEnd,
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
            if (height > 40 && location.isNotEmpty)
              Text(location,
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
  final VoidCallback onTap;
  final void Function(PlanBlock, bool resize, double globalY) onDragStart;
  final void Function(double globalY) onDragUpdate;
  final VoidCallback onDragEnd;

  const _Block({
    required this.block,
    required this.axis,
    required this.todo,
    required this.dragging,
    required this.resizing,
    required this.dragDeltaMin,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        todo == null ? const Color(0xFF4A5B75) : courseColor(todo!.courseId);
    // 拖动中只改预览：移动 → 顶边跟着走、高度不变；缩放 → 顶边不动、高度跟着变
    final topMin = resizing ? block.startMin : block.startMin + dragDeltaMin;
    final endMin = block.endMin + dragDeltaMin;
    final top = (topMin - axis.startMin).toDouble();
    final height = (endMin - (resizing ? block.startMin : topMin)).toDouble();
    return Positioned(
      top: top,
      left: 3,
      right: 3,
      height: height < 12 ? 12 : height,
      child: Listener(
        // ⚠️ 用 Listener 而不是 GestureDetector 的 onPan*：竖直拖动会被外层
        //    SingleChildScrollView 的手势竞技场抢走（实测一点回调都不触发）。
        //    Listener 收原始指针事件、不参与竞技场；又因为我们用
        //    dragOffsetWithScroll（位移 = 手指位移 + 滚动量）换算，
        //    所以哪怕滚动视图跟着动了，块也仍然贴在手指下面。
        onPointerDown: (e) {
          final box = context.findRenderObject() as RenderBox?;
          final h = box?.size.height ?? 0;
          // 按下位置在底部 18vp 内 = 拖底边缩放，否则整块移动
          onDragStart(block, e.localPosition.dy > h - 18, e.position.dy);
        },
        onPointerMove: (e) => onDragUpdate(e.position.dy),
        onPointerUp: (_) => onDragEnd(),
        onPointerCancel: (_) => onDragEnd(),
        child: GestureDetector(
          key: ValueKey('plan-block-${block.id}'),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 2, 3, 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: dragging ? 0.98 : 0.92),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: Colors.white.withValues(alpha: dragging ? 0.85 : 0.25),
                width: dragging ? 1.5 : 1,
              ),
            ),
            child: Stack(
              children: [
                Text(
                  todo?.title ?? '计划块',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: inkPrimary,
                    decoration: block.done ? TextDecoration.lineThrough : null,
                  ),
                ),
                // 底边缩放手柄（只是视觉提示；判定是按按下位置算的）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 8,
                  child: Center(
                    child: Container(
                      key: ValueKey('plan-resize-${block.id}'),
                      width: 22,
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
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
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF8A8A))),
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
  final Map<int, Course> courses;
  final int selectedId;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelect;
  final void Function(Todo t) onPlace;

  const _Tray({
    required this.pool,
    required this.courses,
    required this.selectedId,
    required this.open,
    required this.onToggle,
    required this.onSelect,
    required this.onPlace,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          floatSide, 0, floatSide, tabBarInset + floatGap),
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
            Text('${pool.length}',
                style: const TextStyle(fontSize: 12, color: accentBlue)),
            const Spacer(),
            const Text('展开',
                style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
            const Icon(Icons.expand_less, size: 14, color: Color(0xFFA9B5C9)),
          ],
        ),
      ),
    );
  }

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
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              children: [
                const Text('待安排',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: inkPrimary)),
                const Spacer(),
                Text(selectedId > 0 ? '已选中，点网格空白处放下' : '点选 / ⚡ 一键找空档',
                    style: TextStyle(
                        fontSize: 11,
                        color: selectedId > 0
                            ? accentBlue
                            : const Color(0xFF8B97AC))),
                const SizedBox(width: 10),
                const Text('收起',
                    style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
                const Icon(Icons.expand_more,
                    size: 14, color: Color(0xFFA9B5C9)),
              ],
            ),
          ),
        ),
        if (pool.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Text('没有待安排的事项。先去「待办」里确认几条。',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B97AC))),
          )
        else
          SizedBox(
            height: 122,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
              itemCount: pool.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _poolCard(pool[i]),
            ),
          ),
      ],
    );
  }

  Widget _poolCard(Todo t) {
    final selected = t.id == selectedId;
    final course = t.courseId;
    return GestureDetector(
      key: ValueKey('pool-${t.id}'),
      onTap: () => onSelect(t.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 140,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0x4D2E6BE6) // rgba(46,107,230,0.30)
              : glassTintRow,
          borderRadius: BorderRadius.circular(glassRadius),
          border: Border.all(
              width: selected ? 1.5 : 1,
              color: selected ? accentBlue : glassEdgeSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: inkPrimary)),
            if (course > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: courseColor(courses[course]?.colorIndex ?? 0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(courses[course]?.label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFEAF0FA))),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('预计 ${t.estimateMin} 分钟',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF9BA7BD))),
            ),
            const Spacer(),
            GestureDetector(
              key: ValueKey('pool-find-${t.id}'),
              onTap: () => onPlace(t),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 13, color: accentBlue),
                    SizedBox(width: 2),
                    Text('找空档',
                        style: TextStyle(fontSize: 11, color: accentBlue)),
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
