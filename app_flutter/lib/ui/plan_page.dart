// 计划页（第一版）：日/三日时间轴 + 课表灰带 + 计划块 + 截止标记 + 待安排托盘。
//
// 几何完全沿用 PlanMath：1 分钟 = 1vp，时间窗默认 07:00–24:00，吸附 15 分钟。
// 还没做的：拖动/缩放（PlanMath 的 dropRange/moveRange/resizeRange 已移植并有 fixtures，
// 等交互打磨时接上）、属性面板里的改时间、三日视图的横向拖拽。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/tray_pref.dart';
import '../domain/dates.dart';
import '../domain/plan_math.dart';
import '../domain/validate.dart';
import '../domain/timetable.dart';
import '../model/types.dart';
import 'app_frame.dart';
import 'block_editor.dart';
import 'timetable_page.dart' show gridPad;
import 'palette.dart';
import '../domain/categories.dart';

/// 三日视图列头高度（鸿蒙 `H_COLHEAD = 34`）
const double colHeadH = 34;

/// 截止标记会从网格底边往下挂出自己的一整行，滚动内容底部要给这点余量，
/// 否则滑到底时它会被悬浮的待安排托盘盖掉半截（鸿蒙 `DDL_MARK_ALLOW = 36`）
const double ddlMarkAllow = 36;

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

  /// 「待安排」托盘的展开状态变了（外壳负责写 kv；鸿蒙 `planTrayOpen`）
  final void Function(bool open)? onTrayPref;

  /// 「截止标记」里点一条待办 → 打开它的编辑窗（鸿蒙 DdlExpandPanel 的行为；
  /// 编辑窗在待办页，由外壳统一提供）
  final Future<void> Function(int todoId)? onOpenTodo;

  /// 打开时看哪天 / 是不是三日视图（默认今天、单日）——截图和测试要用
  final DateTime? initialDay;
  final bool initialThreeDay;

  /// 取"现在"的方式。默认 `DateTime.now`，测试可以注入固定时钟。
  /// ⚠️ 为什么需要它：⚡找空档的起点是"今天就从当前时刻开始找"，
  /// 用真实时钟的话，同一条测试白天过、半夜挂（23:25 之后直到 24:00 都被
  /// "睡觉 23:30–24:00" 挡住）—— 实测踩过一次。
  final DateTime Function() now;

  /// 待安排·标签筛选用的自定义类型
  final List<String> customCategories;
  const PlanPage({
    super.key,
    required this.bundle,
    required this.onChanged,
    this.window = defaultWindow,
    this.restWindows = const [],
    this.topInset = 0,
    this.onNotePref,
    this.onTrayPref,
    this.onOpenTodo,
    this.initialDay,
    this.initialThreeDay = false,
    this.now = DateTime.now,
    this.customCategories = const [],
  });

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  static const double _axisW = 46;

  late DateTime _day;
  late bool _threeDay;
  bool _weekView = false;
  int _selectedTodoId = 0; // 托盘里选中、等着落到网格上的那条
  int _selectedLessonId = 0; // 托盘里选中的虚拟课程课时（0 = 没选）

  /// 网格里选中的块（鸿蒙两步模型：第一下选中、第二下开编辑窗）
  int _selectedBlockId = 0;

  /// 待安排当前页：0 待办 / 1 虚拟课程（鸿蒙 POOL_PAGE_*）
  int _trayPage = 0;

  /// 待安排筛选：标签（''=全部）与课程（-1=全部，0=无课程，>0=课程 id）
  String _poolTag = '';
  int _poolCourse = -1;

  /// 计划撤销/重做：快照整份 bundle（最多 30 步）
  final List<({BackupBundle b, String label})> _undo = [];
  final List<({BackupBundle b, String label})> _redo = [];

  /// 视图级双指：未选中块时捏合切 日/三日/周
  final Map<int, Offset> _viewPointers = {};
  double _viewStartDist = 0;
  double _viewLastDist = 0;
  bool _swipeTracking = false;
  Offset _swipeStart = Offset.zero;
  double _swipeDx = 0;
  double _swipeDy = 0;

  /// 待安排托盘是否展开（鸿蒙端 TraySummonBar ↔ TodoPool）
  /// 托盘展开状态（冷启动从 kv 读回，鸿蒙 `loadTrayOpen`）
  bool _trayOpen = planTrayOpen;

  /// 日期条实测高度（首帧用估算值）
  double _dayBarH = 68;

  /// 待安排托盘实测高度（首帧用收起时的估算值；鸿蒙 `bottomPaneH` 同样是量出来的）
  double _trayH = 62;

  /// 瞬时提示（鸿蒙端 showHint）：不占布局、1.8 秒自动消失
  String _hint = '';
  Timer? _hintTimer;
  Timer? _nowTicker;

  /// 双指缩放时屏幕正中那个「±NN min」提示（'' = 不显示）
  String _pinchLabel = '';

  /// 按下双指那一刻的结束分钟（缩放基准，手指抖动不累积误差）
  int _pinchBaseEnd = 0;

  /// 双指缩放预览：正在缩的块 id 与预览结束分钟（0 = 没在缩）
  int _pinchId = 0;
  int _pinchEndMin = 0;

  /// 当前按在画面上的手指（只用于识别双指缩放；不参与手势竞技场）
  final Map<int, Offset> _pointers = {};
  double _pinchBaseDist = 0;

  /// 日/三日横向画布：真正的 PageView（跟手、惯性、吸附由 Flutter 负责）。
  PageController? _pager;
  static const int _pagerCenter = 30;
  DateTime? _pagerAnchor;
  bool? _pagerThree;
  bool _pagerSnapping = false;
  Timer? _pagerSettle;

  PageController? _weekPager;
  DateTime? _weekAnchor;
  bool _weekPagerSnapping = false;
  Timer? _weekSettle;
  static const int _weekPagerCenter = 30;

  // ---- 拖动 / 缩放（见 domain/plan_math.dart 的 moveRange / resizeRange / edgeScroll*）----
  final ScrollController _scroll = ScrollController();

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

  /// 贴边自动滚动：手指停在边缘时由定时器持续推视图（不是只在 move 事件里跳）
  Timer? _autoScrollTimer;
  int _autoScrollDir = 0;
  int _autoScrollStep = 0;

  @override
  void dispose() {
    _hintTimer?.cancel();
    _nowTicker?.cancel();
    _autoScrollTimer?.cancel();
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
    final screen = MediaQuery.sizeOf(context);
    final top = widget.topInset + _dayBarH + floatGap;
    final bottom = screen.height - tabBarInset - _trayH - 12;
    return Rect.fromLTRB(_axisW, top, screen.width, bottom);
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
    // 长按开始拖块时，禁止这一次指针再被当成「左右翻页」
    _swipeTracking = false;
    setState(() {
      _dragId = b.id;
      _dragResize = resize;
      _dragTouchStartY = pos.dy;
      _dragLastY = pos.dy;
      _dragCol = resize ? -1 : _colOfGlobal(pos.dx);
      _dragScrollStart = _scroll.hasClients ? _scroll.offset : 0;
      _dragDeltaMin = 0;
    });
  }

  void _applyDragDelta() {
    if (_dragId == 0) return;
    // 块的位移 = 手指位移 + 滚动量（符号必须是加，见 fixtures 里那条断言）
    final scrollDelta =
        (_scroll.hasClients ? _scroll.offset : 0) - _dragScrollStart;
    final offset = dragOffsetWithScroll(
        (_dragLastY - _dragTouchStartY).round(), scrollDelta.round());
    setState(() => _dragDeltaMin = snap(offset));
  }

  void _autoScrollTick() {
    if (_dragId == 0 || _autoScrollDir == 0 || !_scroll.hasClients) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    final target = (_scroll.offset + _autoScrollDir * _autoScrollStep)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(target);
    _applyDragDelta();
  }

  void _updateAutoScroll(double y) {
    // 边缘按**可视区域**算，不能用网格内容的高度：网格比屏幕高，
    // 原来拿 grid 的 rect.bottom 永远到不了屏幕底边，自动滚动几乎不触发。
    final screenH = MediaQuery.sizeOf(context).height;
    final top = (widget.topInset + _dayBarH + floatGap).round();
    final bottom = (screenH - tabBarInset - _trayH - 12).round();
    const edgeZone = 56;
    const maxStep = 14;
    final dir = edgeScrollDirection(y.round(), top, bottom, edgeZone);
    if (dir == 0 || !_scroll.hasClients) {
      _autoScrollDir = 0;
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    final depth = edgeScrollDepth(y.round(), top, bottom, edgeZone);
    _autoScrollDir = dir;
    _autoScrollStep = edgeScrollStep(depth, edgeZone, maxStep);
    _autoScrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 16), (_) => _autoScrollTick());
  }

  double _dragLastY = 0;

  void _updateDrag(Offset pos) {
    if (_dragId == 0) return;
    final globalY = pos.dy;
    _dragLastY = globalY;
    if (!_dragResize) _dragCol = _colOfGlobal(pos.dx);
    _updateAutoScroll(globalY);
    _applyDragDelta();
  }

  void _endDrag() {
    _autoScrollDir = 0;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
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
    // 鸿蒙松手后的提示：改时长 / 跨天 / 同天挪
    if (resize) {
      _showHint('时长改为 ${range[1] - range[0]} 分钟');
    } else if (targetDate != b.date) {
      _showHint('改到 $targetDate');
    } else {
      _showHint('挪到 ${minToHHmm(range[0])}-${minToHHmm(range[1])}');
    }
    _commit(
        _withBlocks([
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
        ]),
        '调整计划块');
  }

  @override
  void initState() {
    super.initState();
    _day = widget.initialDay ??
        DateTime(widget.now().year, widget.now().month, widget.now().day);
    _threeDay = widget.initialThreeDay;
    if (ambientMotion) {
      _nowTicker = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  Semester get _sem => widget.bundle.semester!;

  TimeAxis get _axis => TimeAxis(widget.window);

  List<DateTime> get _days {
    if (_weekView) {
      final monday = addDays(_day, -(weekdayOf(_day) - 1));
      return [for (var i = 0; i < 7; i++) addDays(monday, i)];
    }
    if (!_threeDay) return [_day];
    // 鸿蒙 `dayDates(date, 3)`：**[前一天, 当天, 后一天]** —— 当天在正中间。
    // 以前写成 [当天, +1, +2]，当天就落在最左列了（用户实测："今日不是显示在正中间"）。
    return [for (var i = -1; i <= 1; i++) addDays(_day, i)];
  }

  void _shift(int days) {
    if (_weekView) {
      setState(() => _day = addDays(_day, days >= 0 ? 7 : -7));
      _weekPagerToDay();
      return;
    }
    setState(() {
      _pageDir = days >= 0 ? 1 : -1;
      _day = addDays(_day, days);
    });
    _pagerToDay();
  }

  void _openDayFromWeek(DateTime day, int minute) {
    setState(() {
      _day = day;
      _weekView = false;
      _threeDay = true;
      _selectedBlockId = 0;
    });
    _showHint('${day.month}/${day.day} ${minToHHmm(minute)}');
    _pagerToDay(animate: false);
  }

  void _jumpToday() {
    setState(() => _day = today());
    if (_weekView) {
      _weekPagerToDay();
    } else {
      _pagerToDay(animate: false);
    }
  }

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
          if (!l.done &&
              !widget.bundle.blocks.any((b) => b.lessonId == l.id) &&
              (_poolCourse <= 0 || l.courseId == _poolCourse))
            l
      ];

  List<Todo> get _pool {
    var list = selectPoolTodos(widget.bundle.todos, widget.bundle.blocks);
    if (_poolTag.isNotEmpty) {
      list = list.where((t) => t.category == _poolTag).toList();
    }
    if (_poolCourse >= 0) {
      list = list.where((t) => t.courseId == _poolCourse).toList();
    }
    return sortPoolTodos(list);
  }

  Future<void> _pickPoolTag() async {
    final opts = allCategoryOptions(widget.customCategories);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF0E1420),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('全部标签', style: TextStyle(color: inkPrimary)),
              trailing: _poolTag.isEmpty
                  ? const Icon(Icons.check, color: accentBlue)
                  : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final o in opts)
              ListTile(
                title: Text(o.label, style: const TextStyle(color: inkPrimary)),
                trailing: _poolTag == o.key
                    ? const Icon(Icons.check, color: accentBlue)
                    : null,
                onTap: () => Navigator.pop(ctx, o.key),
              ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) {
      setState(() {
        _poolTag = choice;
        _selectedTodoId = 0;
        _hint = '';
      });
    }
  }

  Future<void> _pickPoolCourse() async {
    final choices = <(int, String)>[
      (-1, '全部课程'),
      (0, '无课程'),
      for (final c in widget.bundle.courses)
        (c.id, c.shortName.isNotEmpty ? c.shortName : c.name),
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF0E1420),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in choices)
              ListTile(
                title: Text(e.$2, style: const TextStyle(color: inkPrimary)),
                trailing: _poolCourse == e.$1
                    ? const Icon(Icons.check, color: accentBlue)
                    : null,
                onTap: () => Navigator.pop(ctx, e.$1),
              ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) {
      setState(() {
        _poolCourse = choice;
        _selectedTodoId = 0;
        _selectedLessonId = 0;
        _hint = '';
      });
    }
  }

  Todo? _todoOf(int id) {
    for (final t in widget.bundle.todos) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ---------------- 改动 ----------------

  void _commit(BackupBundle next, String label) {
    _undo.add((b: widget.bundle, label: label));
    if (_undo.length > 30) _undo.removeAt(0);
    _redo.clear();
    widget.onChanged(next);
  }

  void _undoPlan() {
    if (_undo.isEmpty) return;
    final last = _undo.removeLast();
    _redo.add((b: widget.bundle, label: last.label));
    widget.onChanged(last.b);
    _showHint('已撤销：${last.label}');
  }

  void _redoPlan() {
    if (_redo.isEmpty) return;
    final next = _redo.removeLast();
    _undo.add((b: widget.bundle, label: next.label));
    widget.onChanged(next.b);
    _showHint('已重做：${next.label}');
  }

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
      _commit(_withBlocks([...widget.bundle.blocks, block]), '排入课时');
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
    _commit(_withBlocks([...widget.bundle.blocks, block]), '排入计划');
    setState(() => _selectedTodoId = 0);
    // 鸿蒙 `doPlace()` 的提示带标题和时段（比「已排到」多信息）
    _showHint('已安排：${todo.title}'
        '（${minToHHmm(startMin)}-${minToHHmm(end)}）');
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

  // ---------------- 日/三日横滑画布 ----------------

  void _ensurePager() {
    if (_pager != null && _pagerThree == _threeDay) return;
    _pager?.dispose();
    _pagerAnchor = _day;
    _pagerThree = _threeDay;
    _pager = PageController(
      initialPage: _pagerCenter,
      viewportFraction: _threeDay ? (1 / 3) : 1.0,
    );
  }

  int _pagerIndexFor(DateTime day) =>
      _pagerCenter + day.difference(_pagerAnchor!).inDays;

  void _pagerToDay({bool animate = true}) {
    _ensurePager();
    final idx = _pagerIndexFor(_day);
    if (idx < 0 || idx > _pagerCenter * 2) {
      // 走得太远：重开画布，把当前日放回正中。
      _pager?.dispose();
      _pager = null;
      _ensurePager();
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pager == null || !_pager!.hasClients) return;
      if (!animate) {
        _pager!.jumpToPage(idx);
      } else {
        _pager!.animateToPage(idx,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic);
      }
    });
  }

  void _onPagerChanged(int index) {
    final d = addDays(_pagerAnchor!, index - _pagerCenter);
    if (formatDate(d) == formatDate(_day)) return;
    setState(() {
      _day = d;
      _pageDir = index > _pagerCenter ? 1 : -1;
      _selectedBlockId = 0;
      _selectedTodoId = 0;
      _selectedLessonId = 0;
    });
  }

  Widget _axisColumn({double? height}) {
    final h = height ?? (_axis.height() + 12);
    final span = _axis.endMin - _axis.startMin;
    return SizedBox(
      width: _axisW,
      height: h,
      child: Stack(
        children: [
          for (final m in _axis.marks)
            Positioned(
              top: ((m - _axis.startMin) / span * h - 5).clamp(0.0, h - 10),
              right: 6,
              child: Text(minToHHmm(m),
                  style: TextStyle(
                      fontSize: height == null ? 12 : 7,
                      color: const Color(0xFFCBD6E8))),
            ),
        ],
      ),
    );
  }

  Widget _pagerHeaderCell(DateTime d) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final selected = formatDate(d) == formatDate(_day);
    final isToday = formatDate(d) == formatDate(widget.now());
    return Container(
      height: colHeadH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: selected ? 0.10 : 0.03),
        border: Border(
            right: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${d.month}/${d.day} 周${names[weekdayOf(d) - 1]}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
                  color: selected ? inkPrimary : const Color(0xFFA9B5C9))),
          if (isToday)
            const Text('今天',
                style: TextStyle(
                    fontSize: 10, height: 1.1, color: Color(0xFF7FA8FF))),
        ],
      ),
    );
  }

  Widget _pagerDay(DateTime d) {
    final single = !_threeDay;
    return Column(
      children: [
        if (_threeDay) _pagerHeaderCell(d),
        SizedBox(
          key: ValueKey('plan-day-${formatDate(d)}'),
          height: _axis.height() + 12,
          child: LayoutBuilder(builder: (ctx, cons) {
            double dragDx = 0;
            if (_dragId != 0 && _dragCol >= 0 && _dragCol < _days.length) {
              final target = _days[_dragCol];
              dragDx = target.difference(d).inDays * cons.maxWidth;
            }
            return _DayColumn(
              axis: _axis,
              now: widget.now(),
              dragId: _dragId,
              dragResize: _dragResize,
              dragDeltaMin: _dragDeltaMin,
              onDragStart: _startDrag,
              onDragUpdate: _updateDrag,
              onDragEnd: _endDrag,
              onPointer: _onBlockPointer,
              lessonTitles: {
                for (final l in widget.bundle.lessons)
                  l.id: lessonTitleOf(l, widget.bundle.courses),
              },
              lessonColors: {
                for (final l in widget.bundle.lessons)
                  l.id: courseColorFor(widget.bundle.courses
                      .where((c) => c.id == l.courseId)
                      .firstOrNull),
              },
              pinchId: _pinchId,
              pinchEndMin: _pinchEndMin,
              day: d,
              sessions: _sessionsOn(d),
              blocks: _blocksOn(d),
              ddls: _ddlOn(d),
              rests: _restsOn(d),
              singleDay: single,
              todoOf: _todoOf,
              onTapMinute: (day, min) {
                if (_selectedTodoId > 0 || _selectedLessonId > 0) {
                  final todo = _todoOf(_selectedTodoId);
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
                final c =
                    widget.bundle.courses.where((x) => x.id == id).firstOrNull;
                return c == null
                    ? ''
                    : (c.shortName.isNotEmpty ? c.shortName : c.name);
              },
              courseColorOf: (id) => courseColorFor(
                  widget.bundle.courses.where((x) => x.id == id).firstOrNull),
              onOpenTodo: widget.onOpenTodo,
              dragDx: dragDx,
            );
          }),
        ),
      ],
    );
  }

  void _queueSnapPager() {
    _pagerSettle?.cancel();
    _pagerSettle = Timer(const Duration(milliseconds: 120), _snapPager);
  }

  void _maybeRecenterPager() {
    if (_pager == null || !_pager!.hasClients) return;
    final page = _pager!.page?.round();
    if (page == null) return;
    if (page < 6 || page > _pagerCenter * 2 - 6) {
      // 画布窗口快滑到边上了：以当前日重新居中，页面数量保持 61 天，
      // 视觉上是同一天，所以可以无限继续滑。
      setState(() => _pagerAnchor = _day);
      _pager!.jumpToPage(_pagerCenter);
    }
  }

  void _snapPager() {
    if (_pagerSnapping || _pager == null || !_pager!.hasClients) return;
    final page = _pager!.page;
    if (page == null) return;
    final idx = page.round().clamp(0, _pagerCenter * 2);
    if ((page - idx).abs() < 0.01) {
      _maybeRecenterPager();
      return;
    }
    _pagerSnapping = true;
    _pager!
        .animateToPage(idx,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic)
        .whenComplete(() {
      _pagerSnapping = false;
      _maybeRecenterPager();
    });
  }

  DateTime _mondayOf(DateTime d) => addDays(d, -(weekdayOf(d) - 1));

  void _ensureWeekPager() {
    if (_weekPager != null) return;
    _weekAnchor = _mondayOf(_day);
    _weekPager = PageController(
      initialPage: _weekPagerCenter,
      viewportFraction: 1,
    );
  }

  void _weekPagerToDay({bool animate = true}) {
    _ensureWeekPager();
    final idx = _weekPagerCenter +
        (_mondayOf(_day).difference(_weekAnchor!).inDays / 7).round();
    if (idx < 0 || idx > _weekPagerCenter * 2) {
      _weekPager?.dispose();
      _weekPager = null;
      _ensureWeekPager();
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _weekPager == null || !_weekPager!.hasClients) return;
      if (!animate) {
        _weekPager!.jumpToPage(idx);
      } else {
        _weekPager!.animateToPage(idx,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic);
      }
    });
  }

  void _queueSnapWeek() {
    _weekSettle?.cancel();
    _weekSettle = Timer(const Duration(milliseconds: 120), _snapWeekPager);
  }

  void _maybeRecenterWeek() {
    if (_weekPager == null || !_weekPager!.hasClients) return;
    final page = _weekPager!.page?.round();
    if (page == null) return;
    if (page < 6 || page > _weekPagerCenter * 2 - 6) {
      setState(() => _weekAnchor = _mondayOf(_day));
      _weekPager!.jumpToPage(_weekPagerCenter);
    }
  }

  void _snapWeekPager() {
    if (_weekPagerSnapping || _weekPager == null || !_weekPager!.hasClients) {
      return;
    }
    final page = _weekPager!.page;
    if (page == null) return;
    final idx = page.round().clamp(0, _weekPagerCenter * 2);
    if ((page - idx).abs() < 0.01) {
      _maybeRecenterWeek();
      return;
    }
    _weekPagerSnapping = true;
    _weekPager!
        .animateToPage(idx,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic)
        .whenComplete(() {
      _weekPagerSnapping = false;
      _maybeRecenterWeek();
    });
  }

  void _onWeekPagerChanged(int index) {
    _ensureWeekPager();
    final monday = addDays(_weekAnchor!, (index - _weekPagerCenter) * 7);
    final wd = weekdayOf(_day) - 1;
    final d = addDays(monday, wd);
    if (formatDate(d) == formatDate(_day)) return;
    setState(() {
      _day = d;
      _selectedBlockId = 0;
      _selectedTodoId = 0;
      _selectedLessonId = 0;
    });
  }

  Widget _weekHeaderCell(DateTime d) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final selected = formatDate(d) == formatDate(_day);
    final isToday = formatDate(d) == formatDate(widget.now());
    return SizedBox(
      height: colHeadH,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('周${names[weekdayOf(d) - 1]}',
              maxLines: 1,
              style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
                  color: selected ? inkPrimary : const Color(0xFFA9B5C9))),
          Text('${d.month}/${d.day}',
              maxLines: 1,
              style: TextStyle(
                  fontSize: 9,
                  height: 1.1,
                  color: selected
                      ? const Color(0xFFDCE4F0)
                      : const Color(0xFF8B97AC))),
          if (isToday)
            const Text('今天',
                maxLines: 1,
                style: TextStyle(
                    fontSize: 8, height: 1.1, color: Color(0xFF7FA8FF))),
        ],
      ),
    );
  }

  Widget _weekPage(List<DateTime> days, double gridH) {
    return Column(
      children: [
        Row(
          children: [
            for (final d in days) Expanded(child: _weekHeaderCell(d)),
          ],
        ),
        SizedBox(
          height: gridH,
          child: _WeekGrid(
            axis: _axis,
            axisW: _axisW,
            days: days,
            now: widget.now(),
            height: gridH,
            showAxis: false,
            sessions: {for (final d in days) formatDate(d): _sessionsOn(d)},
            blocks: {for (final d in days) formatDate(d): _blocksOn(d)},
            rests: {for (final d in days) formatDate(d): _restsOn(d)},
            todoOf: _todoOf,
            onTapDay: _openDayFromWeek,
            courseColorOf: (id) => courseColorFor(
                widget.bundle.courses.where((x) => x.id == id).firstOrNull),
            lessonTitles: {
              for (final l in widget.bundle.lessons)
                l.id: lessonTitleOf(l, widget.bundle.courses),
            },
            lessonColors: {
              for (final l in widget.bundle.lessons)
                l.id: courseColorFor(widget.bundle.courses
                    .where((c) => c.id == l.courseId)
                    .firstOrNull),
            },
          ),
        ),
      ],
    );
  }

  Widget _weekPagerView(BuildContext context) {
    _ensureWeekPager();
    final gridH = (MediaQuery.sizeOf(context).height -
            widget.topInset -
            _dayBarH -
            floatGap -
            tabBarInset -
            _trayH -
            colHeadH)
        .clamp(160.0, 1200.0);
    final totalH = gridH + colHeadH;
    return SizedBox(
      height: totalH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _axisW,
            child: Column(
              children: [
                const SizedBox(height: colHeadH),
                _axisColumn(height: gridH),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollEndNotification) {
                  if (ambientMotion) {
                    _queueSnapWeek();
                  } else {
                    _snapWeekPager();
                  }
                } else if (ambientMotion && n is ScrollUpdateNotification) {
                  _queueSnapWeek();
                }
                return false;
              },
              child: PageView.builder(
                key: const PageStorageKey('plan-week-pager'),
                controller: _weekPager,
                pageSnapping: false,
                physics: _dragId != 0
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                itemCount: _weekPagerCenter * 2 + 1,
                onPageChanged: _onWeekPagerChanged,
                itemBuilder: (ctx, i) {
                  final monday =
                      addDays(_weekAnchor!, (i - _weekPagerCenter) * 7);
                  final days = [for (var k = 0; k < 7; k++) addDays(monday, k)];
                  return _weekPage(days, gridH);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pagerView(BuildContext context) {
    _ensurePager();
    final gridH = _axis.height() + 12;
    final totalH = gridH + (_threeDay ? colHeadH : 0.0);
    return SizedBox(
      height: totalH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              if (_threeDay) SizedBox(height: colHeadH, width: _axisW),
              _axisColumn(),
            ],
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollEndNotification) {
                  if (ambientMotion) {
                    _queueSnapPager();
                  } else {
                    _snapPager();
                  }
                } else if (ambientMotion && n is ScrollUpdateNotification) {
                  _queueSnapPager();
                }
                return false;
              },
              child: PageView.builder(
                key: const PageStorageKey('plan-day-pager'),
                controller: _pager,
                // 鸿蒙是「连续画布 + 惯性停止后吸附」：PageView 默认的
                // pageSnapping 会把一次甩动硬限制成一页；这里关掉它，
                // 让惯性可以连续跑过多页，松手后再吸附到最近一天。
                pageSnapping: false,
                physics: _dragId != 0
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                itemCount: _pagerCenter * 2 + 1,
                onPageChanged: _onPagerChanged,
                itemBuilder: (ctx, i) {
                  final d = addDays(_pagerAnchor!, i - _pagerCenter);
                  return _pagerDay(d);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final days = _days;
    // 日期条是**悬浮浮窗**（鸿蒙端 DayBarFloat）：内容从它下面滑过，所以滚动区顶部留
    // 页头 + 日期条的空；底部留导航栏 + 待安排托盘的空。
    // 鸿蒙 `topBarsBlockH() = topInset + FLOAT_GAP + H_DAYBAR + FLOAT_GAP`：
    // 日期条与网格之间**要留一条缝**（多个浮窗相连时的空行）
    final dayBarBlock = widget.topInset + _dayBarH + floatGap;
    // ⚠️ 末尾那 36 是鸿蒙 `DDL_MARK_ALLOW`：截止标记挂在网格底边**往下**一行，
    // 不留这点余量的话，滑到底时它的下半截会被悬浮的待安排托盘盖住。
    // 托盘高度是**量出来的**（鸿蒙 `bottomPaneH` 也是 onAreaChange 量的）：
    // 写死 62/176 时，托盘里的课时或提示多一行，滚动区底部就会多/少一截。
    // 鸿蒙：`bottom: bottomInset + FLOAT_GAP + bottomPaneH + FLOAT_GAP + DDL_MARK_ALLOW`
    // （bottomInset = 导航栏 + 一条缝），这里 `tabBarInset` 就等于 `bottomInset + FLOAT_GAP`
    final trayBlock = tabBarInset + floatGap + _trayH + floatGap + ddlMarkAllow;
    return Listener(
      onPointerDown: _onViewPointerDown,
      onPointerMove: _onViewPointerMove,
      onPointerUp: _onViewPointerUp,
      onPointerCancel: _onViewPointerUp,
      child: Stack(
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
              // ⚠️ 左右 **不**留 FLOAT_SIDE：鸿蒙 `PlanDayView` 的滚动内容只给了上下
              // padding，网格是满宽的（FLOAT_SIDE 只作用在日期栏/托盘这两个浮窗上）。
              // 安卓原来左右各留 10，双机对比时整张网格右移了 10vp。
              padding: EdgeInsets.fromLTRB(0, dayBarBlock, 0, trayBlock),
              child: _weekView ? _weekPagerView(context) : _pagerView(context),
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
                // 「今天 / 逾期 N 天」也走注入的时钟（截图/测试才能钉在 10/16）
                today: widget.now(),
                threeDay: _threeDay,
                weekView: _weekView,
                onWeek: () {
                  setState(() {
                    _weekView = true;
                    _threeDay = false;
                    _selectedBlockId = 0;
                  });
                  _weekPagerToDay(animate: false);
                },
                // 鸿蒙 DayBarFloat 的 ‹ › 永远只挪 1 天（三日视图也一样，不是"三日一跳"）
                onPrev: () => _shift(-1),
                onNext: () => _shift(1),
                onUndo: _undoPlan,
                onRedo: _redoPlan,
                canUndo: _undo.isNotEmpty,
                canRedo: _redo.isNotEmpty,
                onToday: _jumpToday,
                onDay: () {
                  setState(() {
                    _threeDay = false;
                    _weekView = false;
                    _selectedBlockId = 0;
                  });
                  _pagerToDay(animate: false);
                },
                onThreeDay: () {
                  setState(() {
                    _threeDay = true;
                    _weekView = false;
                    _selectedBlockId = 0;
                  });
                  _pagerToDay(animate: false);
                },
              ),
            ),
          ),
          // 待安排托盘：浮在导航栏之上
          Positioned(
            left: 0,
            right: 0,
            bottom: tabBarInset,
            child: MeasureSize(
              onSize: (size) {
                if ((size.height - _trayH).abs() > 0.5) {
                  setState(() => _trayH = size.height);
                }
              },
              child: _Tray(
                pool: _pool,
                lessons: _lessonPool,
                page: _trayPage,
                onPage: (p) => setState(() {
                  _trayPage = p;
                  _selectedTodoId = 0;
                  _selectedLessonId = 0;
                  _dragId = 0;
                  _hint = '';
                }),
                tag: _poolTag,
                courseFilter: _poolCourse,
                customCategories: widget.customCategories,
                onPickTag: _pickPoolTag,
                onPickCourse: _pickPoolCourse,
                selectedLessonId: _selectedLessonId,
                courses: {for (final c in widget.bundle.courses) c.id: c},
                selectedId: _selectedTodoId,
                open: _trayOpen,
                onToggle: () {
                  setState(() => _trayOpen = !_trayOpen);
                  widget.onTrayPref?.call(_trayOpen);
                },
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
          ),
          // 双指缩放：屏幕正中的深色 ±NN min 提示（鸿蒙 `pinchLabel`，30 号粗体）
          if (_pinchLabel.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xE00C121C), // rgba(12,18,28,0.88)
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(_pinchLabel,
                        style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                  ),
                ),
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
      ),
    );
  }

  void _onViewPointerDown(PointerDownEvent e) {
    _viewPointers[e.pointer] = e.position;
    if (_viewPointers.length == 1) {
      _swipeStart = e.position;
      _swipeDx = 0;
      _swipeDy = 0;
      _swipeTracking = _insidePlanViewport(e.position);
    }
    if (_viewPointers.length == 2) {
      _swipeTracking = false;
      final p = _viewPointers.values.take(2).toList();
      _viewStartDist = (p[0] - p[1]).distance;
      _viewLastDist = _viewStartDist;
    }
  }

  bool _insidePlanViewport(Offset pos) {
    final rect = _gridRect();
    if (rect == null) return false;
    final screenH = MediaQuery.sizeOf(context).height;
    final top = widget.topInset + _dayBarH + floatGap;
    final bottom = screenH - tabBarInset - _trayH - 12;
    return pos.dy >= top &&
        pos.dy <= bottom &&
        pos.dx >= rect.left &&
        pos.dx <= rect.right;
  }

  int get _pageDaySpan => _weekView ? 7 : 1;

  int _pageDir = 1;

  void _onSwipeEnd() {
    // 日/三日/周的横向翻页都交给 PageView（跟手、惯性、吸附）。
  }

  Widget _animatedPage(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 230),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (c, animation) => SlideTransition(
        position:
            Tween<Offset>(begin: Offset(_pageDir * 0.10, 0), end: Offset.zero)
                .animate(animation),
        child: FadeTransition(opacity: animation, child: c),
      ),
      child: KeyedSubtree(
        key: ValueKey('plan-page-${formatDate(_day)}-$_weekView-$_threeDay'),
        child: child,
      ),
    );
  }

  void _onViewPointerMove(PointerMoveEvent e) {
    if (!_viewPointers.containsKey(e.pointer)) return;
    _viewPointers[e.pointer] = e.position;
    if (_viewPointers.length == 1 && _swipeTracking) {
      _swipeDx = e.position.dx - _swipeStart.dx;
      _swipeDy = e.position.dy - _swipeStart.dy;
    }
    if (_viewPointers.length == 2 && _pinchId == 0) {
      final p = _viewPointers.values.take(2).toList();
      _viewLastDist = (p[0] - p[1]).distance;
    }
  }

  void _onViewPointerUp(PointerEvent e) {
    final wasSingle = _viewPointers.length == 1;
    _viewPointers.remove(e.pointer);
    if (_viewPointers.isEmpty && _viewStartDist > 1 && _pinchId == 0) {
      final ratio = _viewLastDist / _viewStartDist;
      _switchViewByPinch(ratio);
    } else if (_viewPointers.isEmpty && wasSingle) {
      _onSwipeEnd();
    }
    if (_viewPointers.isEmpty) {
      _viewStartDist = 0;
      _viewLastDist = 0;
      _swipeTracking = false;
    }
  }

  void _switchViewByPinch(double ratio) {
    // 和鸿蒙一致：**张开 = 放大**（周 → 三日 → 日），捏合 = 缩小（日 → 三日 → 周）
    if (ratio > 1.2) {
      if (_weekView) {
        setState(() {
          _weekView = false;
          _threeDay = true;
        });
        _showHint('已切到三日视图');
      } else if (_threeDay) {
        setState(() => _threeDay = false);
        _showHint('已切到日视图');
      }
    } else if (ratio < 0.8) {
      if (_weekView) return;
      if (_threeDay) {
        setState(() {
          _weekView = true;
          _threeDay = false;
        });
        _showHint('已切到周视图');
      } else {
        setState(() => _threeDay = true);
        _showHint('已切到三日视图');
      }
    }
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
                    doneAt: next ? DateTime.now().millisecondsSinceEpoch : 0,
                  )
                : l)
            .toList()
        : widget.bundle.lessons;
    _commit(
        BackupBundle(
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
        ),
        '切换课时完成');
  }

  int _lessonDurationOf(VirtualLesson l) {
    Course? course;
    for (final c in widget.bundle.courses) {
      if (c.id == l.courseId) course = c;
    }
    final raw =
        l.durationMin > 0 ? l.durationMin : (course?.lessonDurationMin ?? 90);
    return ((raw / 5).round() * 5).clamp(15, 200);
  }

  /// 虚拟课时的一讲：时长 = 单讲覆盖 → 课程默认 → 90，再 5 分钟取整/夹取。
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
    final duration = _lessonDurationOf(l);
    final slot = findFreeSlot(_axis, busy, rest, duration, from);
    if (slot < 0) {
      _showHint('这天（或剩余时间）排不下了，换一天试试');
      return;
    }
    setState(() => _selectedLessonId = l.id);
    _place(day, slot, duration);
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
      _pinchBaseEnd = b.endMin;
      _pinchEndMin = b.endMin;
      _pinchLabel = pinchDeltaLabel(0);
    });
  }

  void _pinchUpdate(PlanBlock b, double scale) {
    if (_pinchId != b.id) return;
    final base = b.endMin - b.startMin;
    final dur = (base * scale).round().clamp(15, _axis.endMin - b.startMin);
    setState(() {
      _pinchEndMin = b.startMin + dur;
      _pinchLabel = pinchDeltaLabel(_pinchEndMin - _pinchBaseEnd);
    });
  }

  void _pinchEnd(PlanBlock b) {
    final end = _pinchEndMin;
    final id = _pinchId;
    setState(() {
      _pinchId = 0;
      _pinchEndMin = 0;
      _pinchLabel = '';
    });
    if (id == 0 || end == 0 || end == b.endMin) return;
    // 鸿蒙 `endPinch`：松手后弹「时长改为 N 分钟」
    _showHint('时长改为 ${end - b.startMin} 分钟');
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
  final DateTime today;
  final bool threeDay;
  final bool weekView;
  final VoidCallback onWeek;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onToday;
  final VoidCallback onDay;
  final VoidCallback onThreeDay;

  const _DayBar({
    required this.day,
    required this.today,
    required this.threeDay,
    required this.weekView,
    required this.onWeek,
    required this.onPrev,
    required this.onNext,
    required this.onUndo,
    required this.onRedo,
    required this.canUndo,
    required this.canRedo,
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
      // 鸿蒙 `DayBarFloat` 的外层是 `.padding({ top: topInset + FLOAT_GAP })`、
      // 底下不留边距；网格内容的 padding 再 + FLOAT_GAP（见 build 里 dayBarBlock）
      margin: const EdgeInsets.fromLTRB(floatSide, floatGap, floatSide, 0),
      // 鸿蒙 DayBarFloat：padding 左 8 / 右 12 / 上 10 / 下 8
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 8),
      child: Row(
        children: [
          _BarTap(
            onTap: canUndo ? onUndo : null,
            child: Icon(Icons.undo,
                size: 18,
                color: canUndo ? accentBlue : const Color(0xFF4B5668)),
          ),
          _BarTap(
            onTap: canRedo ? onRedo : null,
            child: Icon(Icons.redo,
                size: 18,
                color: canRedo ? accentBlue : const Color(0xFF4B5668)),
          ),
          _BarTap(
            onTap: onPrev,
            // 鸿蒙 `DayBarFloat` 用的是文字箭头 `Text('‹')` 22 号（不是 Material 图标）
            child: const Text('‹',
                style: TextStyle(fontSize: 22, color: accentBlue)),
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
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                ),
                Text(relativeDayText(day, today),
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 12, height: 1.2, color: Color(0xFF94A0B5))),
              ],
            ),
          ),
          _BarTap(
            onTap: onNext,
            child: const Text('›',
                style: TextStyle(fontSize: 22, color: accentBlue)),
          ),
          const SizedBox(width: 6),
          _Chip(text: '日', selected: !threeDay && !weekView, onTap: onDay),
          _Chip(text: '三日', selected: threeDay, onTap: onThreeDay),
          _Chip(text: '周', selected: weekView, onTap: onWeek),
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
  final VoidCallback? onTap;
  const _BarTap({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
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
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
                      if (days.length >= 7) ...[
                        // 周视图 7 列每列只有 ~44vp：拆成「周一 / 11/9」两行，
                        // 不能再用「11/9 周一」一整串，否则相邻列会糊在一起。
                        Text('周${weekdayCn[weekdayOf(days[i]) - 1]}',
                            maxLines: 1,
                            style: TextStyle(
                                fontSize: 10,
                                height: 1.1,
                                fontWeight: i == center
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                                color: i == center
                                    ? inkPrimary
                                    : const Color(0xFFA9B5C9))),
                        Text('${days[i].month}/${days[i].day}',
                            maxLines: 1,
                            style: TextStyle(
                                fontSize: 9,
                                height: 1.1,
                                color: i == center
                                    ? const Color(0xFFDCE4F0)
                                    : const Color(0xFF8B97AC))),
                        if (formatDate(days[i]) == now)
                          const Text('今天',
                              maxLines: 1,
                              style: TextStyle(
                                  fontSize: 8,
                                  height: 1.1,
                                  color: Color(0xFF7FA8FF))),
                      ] else ...[
                        // 三列时列宽只有 ~105vp：等比缩小，绝不折行
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
                          const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('今天',
                                maxLines: 1,
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.1,
                                    color: Color(0xFF7FA8FF))),
                          ),
                      ],
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

/// 鸿蒙 `WeekCanvas`：整周整天压成一屏，只读；点某天 → 放大到以该天为中心的三日。
/// 和日/三日网格用同一份 sessions/blocks，但不是把 1 分钟的网格缩小 7 份。
class _WeekGrid extends StatelessWidget {
  final TimeAxis axis;
  final double axisW;
  final List<DateTime> days;
  final DateTime now;
  final double height;
  final bool showAxis;
  final Map<String, List<CourseSession>> sessions;
  final Map<String, List<PlanBlock>> blocks;
  final Map<String, List<RestWindow>> rests;
  final Todo? Function(int) todoOf;
  final void Function(DateTime, int) onTapDay;
  final Color Function(int) courseColorOf;
  final Map<int, String> lessonTitles;
  final Map<int, Color> lessonColors;

  const _WeekGrid({
    required this.axis,
    required this.axisW,
    required this.days,
    required this.now,
    required this.height,
    this.showAxis = true,
    required this.sessions,
    required this.blocks,
    required this.rests,
    required this.todoOf,
    required this.onTapDay,
    required this.courseColorOf,
    required this.lessonTitles,
    required this.lessonColors,
  });

  double _y(int minute) =>
      (minute - axis.startMin) / (axis.endMin - axis.startMin) * height;

  String _title(PlanBlock b) {
    final t = todoOf(b.todoId);
    if (t != null) return t.title;
    final l = lessonTitles[b.lessonId];
    return l == null || l.isEmpty ? '计划块' : l;
  }

  @override
  Widget build(BuildContext context) {
    final hours = axis.marks;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAxis)
              SizedBox(
                width: axisW,
                child: Stack(
                  children: [
                    for (final m in hours)
                      Positioned(
                        top: (_y(m) - 5).clamp(0.0, height - 10),
                        right: 3,
                        child: Text(minToHHmm(m),
                            style: const TextStyle(
                                fontSize: 7, color: Color(0xFFA9B5C9))),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: GestureDetector(
                        key: ValueKey('plan-day-${formatDate(d)}'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (e) {
                          final minute = axis.startMin +
                              (e.localPosition.dy /
                                      height *
                                      (axis.endMin - axis.startMin))
                                  .round();
                          onTapDay(d, minute);
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // 今天列淡淡高亮
                            if (formatDate(d) == formatDate(now))
                              Positioned.fill(
                                child: Container(
                                    color:
                                        Colors.white.withValues(alpha: 0.06)),
                              ),
                            // 禁排底纹
                            for (final w in rests[formatDate(d)] ?? const [])
                              Positioned(
                                top: _y(w.startMin),
                                height: (_y(w.endMin) - _y(w.startMin))
                                    .clamp(1.0, height),
                                left: 0,
                                right: 0,
                                child: Container(
                                    color:
                                        Colors.white.withValues(alpha: 0.045)),
                              ),
                            // 小时线
                            for (final m in hours)
                              Positioned(
                                top: _y(m),
                                left: 0,
                                right: 0,
                                child: Container(
                                    height: 1,
                                    color:
                                        Colors.white.withValues(alpha: 0.07)),
                              ),
                            // 课程灰/彩带
                            for (final s in sessions[formatDate(d)] ?? const [])
                              Positioned(
                                top: _y(s.startMin),
                                height: (_y(s.endMin) - _y(s.startMin))
                                    .clamp(1.0, height),
                                left: 1,
                                right: 1,
                                child: Container(
                                  // 与日/三日的课程灰带一致：白 0.10、圆角、居中灰字；
                                  // 课程色只属于计划块。
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 1),
                                  alignment: Alignment.center,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(s.course.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              fontSize: 6,
                                              height: 1.0,
                                              color: Color(0xFFA9B5C9))),
                                      if (_y(s.endMin) - _y(s.startMin) > 14 &&
                                          s.location.isNotEmpty)
                                        Text(s.location,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                fontSize: 5,
                                                height: 1.0,
                                                color: Color(0xFF8B97AC))),
                                    ],
                                  ),
                                ),
                              ),
                            // 计划块
                            for (final b in blocks[formatDate(d)] ?? const [])
                              Positioned(
                                top: _y(b.startMin),
                                height: (_y(b.endMin) - _y(b.startMin))
                                    .clamp(1.0, height),
                                left: 1,
                                right: 1,
                                child: Opacity(
                                  opacity: b.done ? 0.5 : 0.95,
                                  child: Container(
                                    // 与日/三日计划块一致：课程/课时实色底、圆角、
                                    // 考试红框、完成半透明；只缩字号和内边距。
                                    decoration: BoxDecoration(
                                      color: b.lessonId > 0
                                          ? (lessonColors[b.lessonId] ??
                                              const Color(0xFF4A5B75))
                                          : courseColorOf(
                                              todoOf(b.todoId)?.courseId ?? 0),
                                      borderRadius: BorderRadius.circular(3),
                                      border: todoOf(b.todoId)?.category ==
                                              TodoCategory.exam
                                          ? Border.all(
                                              color: const Color(0xFFFF5A5A),
                                              width: 1.5)
                                          : null,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 1),
                                    alignment: Alignment.centerLeft,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_y(b.endMin) - _y(b.startMin) > 8)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(right: 1),
                                            child: Text(b.done ? '●' : '○',
                                                style: TextStyle(
                                                    fontSize: 5,
                                                    height: 1.0,
                                                    color: b.done
                                                        ? const Color(
                                                            0xFF7FA8FF)
                                                        : Colors.white)),
                                          ),
                                        Flexible(
                                          child: Text(_title(b),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 5.5,
                                                  height: 1.0,
                                                  fontWeight: FontWeight.w500,
                                                  color: Color(0xFFF2F5FA))),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            // 当前时间红线
                            if (formatDate(d) == formatDate(now) &&
                                now.hour * 60 + now.minute >= axis.startMin &&
                                now.hour * 60 + now.minute <= axis.endMin)
                              Positioned(
                                top: _y(now.hour * 60 + now.minute),
                                left: 0,
                                right: 0,
                                child: Container(
                                    height: 1, color: const Color(0xFFFF5A5F)),
                              ),
                          ],
                        ),
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

class _Grid extends StatelessWidget {
  final TimeAxis axis;
  final double axisW;
  final List<DateTime> days;
  final DateTime now;
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

  /// 课程 id → 颜色（截止面板里的课程小胶囊用，鸿蒙 `colorOf`）
  final Color Function(int) courseColorOf;

  /// 截止面板点一条 → 打开待办编辑窗
  final Future<void> Function(int todoId)? onOpenTodo;

  // 拖动 / 缩放
  final int dragId;
  final bool dragResize;
  final int dragDeltaMin;

  /// 拖动中的目标列（-1 = 不跨天 / 缩放）；用来把块预览画到目标天
  final int dragCol;
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
    required this.axis,
    required this.axisW,
    required this.days,
    required this.now,
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
    required this.courseColorOf,
    required this.onOpenTodo,
    required this.dragId,
    required this.dragResize,
    required this.dragDeltaMin,
    required this.dragCol,
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
    // 跨天拖拽预览：把被拖的块从原列摘出来，临时画到目标列（松手才真正改日期）。
    PlanBlock? dragged;
    if (dragId != 0) {
      for (final list in blocks.values) {
        for (final b in list) {
          if (b.id == dragId) dragged = b;
        }
      }
    }

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
                      // 鸿蒙 `Text(minToHHmm(mark)).width(40).textAlign(End)` + 分隔线 left 6
                      // → 刻度右边缘在 40vp（AXIS_W 46 - 6）
                      right: 6,
                      child: Text(minToHHmm(m),
                          // 鸿蒙端 LAYOUT.hour=12、颜色 #CBD6E8（时间刻度是最不能含糊的）
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFCBD6E8))),
                    ),
                ],
              ),
            ),
            Expanded(
              // 三日视图的列间分隔线（鸿蒙 `ColumnSeparators`：宽 1、白 0.12，
              // 只画列与列之间，单日视图没有 —— 画在日期列的上层会被课程块压住）
              child: LayoutBuilder(builder: (ctx, c) {
                final colW = c.maxWidth / days.length;
                double dragDx = 0;
                if (dragged != null && dragCol >= 0) {
                  final src =
                      days.indexWhere((d) => formatDate(d) == dragged!.date);
                  if (src >= 0) dragDx = (dragCol - src) * colW;
                }
                return Stack(
                  children: [
                    Row(
                      children: [
                        for (final d in days)
                          Expanded(
                            child: _DayColumn(
                              key: ValueKey('plan-day-${formatDate(d)}'),
                              axis: axis,
                              now: now,
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
                              dragDx: dragDx,
                              todoOf: todoOf,
                              onTapMinute: onTapMinute,
                              onTapBlock: onTapBlock,
                              onToggleDone: onToggleDone,
                              selectedBlockId: selectedBlockId,
                              courseLabelOf: courseLabelOf,
                              courseColorOf: courseColorOf,
                              onOpenTodo: onOpenTodo,
                            ),
                          ),
                      ],
                    ),
                    for (var i = 1; i < days.length; i++)
                      Positioned(
                        left: colW * i,
                        top: 0,
                        bottom: 0,
                        child: Container(
                            width: 1,
                            color: Colors.white.withValues(alpha: 0.12)),
                      ),
                  ],
                );
              }),
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
  final DateTime now;
  final List<CourseSession> sessions;
  final List<PlanBlock> blocks;
  final List<DdlGroup> ddls;
  final List<RestWindow> rests;
  final bool singleDay;
  final double dragDx;
  final Todo? Function(int) todoOf;
  final void Function(DateTime, int) onTapMinute;
  final void Function(PlanBlock) onTapBlock;
  final void Function(PlanBlock) onToggleDone;
  final int selectedBlockId;
  final String Function(int) courseLabelOf;
  final Color Function(int) courseColorOf;
  final Future<void> Function(int todoId)? onOpenTodo;

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
    required this.now,
    required this.sessions,
    required this.blocks,
    required this.ddls,
    required this.rests,
    required this.singleDay,
    required this.dragDx,
    required this.todoOf,
    required this.onTapMinute,
    required this.onTapBlock,
    required this.onToggleDone,
    required this.selectedBlockId,
    required this.courseLabelOf,
    required this.courseColorOf,
    this.onOpenTodo,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final min = axis.startMin + details.localPosition.dy.round();
        onTapMinute(day, snap(min));
      },
      // 单日视图没有竖分隔线（鸿蒙 `ColumnSeparators` 只在 `viewCols > COLS_DAY` 时画）
      child: Stack(
        clipBehavior: Clip.none,
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
          // 当前时间红线：只在今天且落在时间窗内时画
          if (formatDate(day) == formatDate(now) &&
              now.hour * 60 + now.minute >= axis.startMin &&
              now.hour * 60 + now.minute <= axis.endMin)
            Positioned(
              top: (now.hour * 60 + now.minute - axis.startMin).toDouble(),
              left: 0,
              right: 0,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(height: 1.5, color: const Color(0xFFFF5A5F)),
                  Positioned(
                    left: 1,
                    top: -3,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          color: Color(0xFFFF5A5F), shape: BoxShape.circle),
                    ),
                  ),
                ],
              ),
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
              dragDx: dragId == b.id ? dragDx : 0,
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
              courseColorOf: courseColorOf,
            ),
          // 截止标记
          for (final g in ddls)
            _DdlMark(
              key: ValueKey('ddl-${formatDate(day)}-${g.minute}'),
              top: (g.minute - axis.startMin).toDouble(),
              label: g.todos.length > 1
                  ? '⚑ ${g.todos.length} 项截止'
                  : '⚑ ${g.todos.first.title} 截止',
              group: g,
              day: formatDate(day),
              // 三日视图才给标题加 MM-DD 前缀（鸿蒙 `viewCols > COLS_DAY`）
              datePrefix: !singleDay,
              courseLabelOf: courseLabelOf,
              courseColorOf: courseColorOf,
              onOpenTodo: onOpenTodo,
            ),
        ],
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
  final double dragDx;

  /// 虚拟课时的标题/课程色（todoId=0 且 lessonId>0 时用）
  final String? lessonTitle;
  final Color? lessonColor;

  /// 双指缩放预览的结束分钟（0 = 没在缩这个块）
  final int pinchEndMin;

  /// 是否选中（选中 = 2px 白框）
  final bool selected;

  /// 所属课程简称（副文字 / 紧凑标题用；空 = 没课程）
  final String courseLabel;

  /// 课程 id → 颜色。⚠️ 必须按课程的 `colorIndex` 取色，
  /// 不能拿 `courseId` 当色号（鸿蒙 `colorOf(courseId)` 也是先找课程再取 colorIndex）
  final Color Function(int) courseColorOf;
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
    required this.dragDx,
    this.lessonTitle,
    this.lessonColor,
    required this.pinchEndMin,
    required this.selected,
    required this.courseLabel,
    required this.courseColorOf,
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
        ? courseColorOf(todo!.courseId)
        : (lessonColor ?? const Color(0xFF4A5B75));
    final topMin = resizing ? block.startMin : block.startMin + dragDeltaMin;
    final top = (topMin - axis.startMin).toDouble();
    final h = _paintedH;
    final compact = h < compactThreshold;
    final opacity = dragging ? 0.72 : (block.done ? 0.5 : 0.95);
    final isExam = todo?.category == TodoCategory.exam;
    final showBorder = selected || dragging || isExam;

    final content = compact
        // 紧凑排版：单行「课程简称·标题 + 开始时间」，不画完成圆圈
        ? Container(
            width: double.infinity,
            height: double.infinity,
            // 鸿蒙紧凑块：`.padding({ left: 7, right: 5 })`（没有上下内边距）
            padding: const EdgeInsets.only(left: 7, right: 5),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(_compactTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: inkPrimary)),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(minToHHmm(block.startMin),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 9, color: Color(0xFFCBD6E8))),
                ),
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
                          // 鸿蒙计划块**不加删除线**：完成的块靠 ○→● 与 0.5 透明度表达
                          style: TextStyle(
                              fontSize: 14,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              color: inkPrimary)),
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
            onDragStart(block, e.localPosition.dy > bh - 18, e.globalPosition);
          },
          onLongPressMoveUpdate: (e) => onDragUpdate(e.globalPosition),
          onLongPressEnd: (_) => onDragEnd(),
          onLongPressCancel: onDragEnd,
          child: Transform.translate(
            offset: Offset(dragDx, 0),
            child: Opacity(
              key: ValueKey('plan-block-${block.id}'),
              opacity: opacity,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  border: showBorder
                      ? Border.all(
                          color: selected || dragging
                              ? const Color(0xFFF2F5FA)
                              : const Color(0xFFFF5A5A),
                          width: 2)
                      : null,
                  boxShadow: isExam && !selected
                      ? const [
                          BoxShadow(
                              color: Color(0x8CFF5A5A),
                              blurRadius: 7,
                              offset: Offset.zero)
                        ]
                      : null,
                ),
                clipBehavior: Clip.hardEdge,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 截止标记（鸿蒙 `DdlMarkers` 里那一条「⚑ … 截止」）。
///
/// 点开 = **挂在标记下方的浮层**（鸿蒙 `bindPopup`：placement Bottom、无箭头、宽度 300、
/// 无遮罩、点外面自动收起）。原来这里是 `showDialog`，遮罩会把整页压暗 —— 双机截图对比时
/// 一眼就看出来不是同一个东西。
class _DdlMark extends StatefulWidget {
  final double top;
  final String label;
  final DdlGroup group;
  final String day;

  /// 三日视图才在标题前加 `MM-DD `（鸿蒙 `viewCols > COLS_DAY`）
  final bool datePrefix;
  final String Function(int) courseLabelOf;
  final Color Function(int) courseColorOf;
  final Future<void> Function(int todoId)? onOpenTodo;

  const _DdlMark({
    super.key,
    required this.top,
    required this.label,
    required this.group,
    required this.day,
    required this.datePrefix,
    required this.courseLabelOf,
    required this.courseColorOf,
    this.onOpenTodo,
  });

  @override
  State<_DdlMark> createState() => _DdlMarkState();
}

class _DdlMarkState extends State<_DdlMark> {
  /// 同一时间只开一个 —— 鸿蒙那边只有一个 `ddlOpenKey`，开另一个就等于关这个
  static _DdlMarkState? _openOne;

  final GlobalKey _anchor = GlobalKey();
  OverlayEntry? _entry;

  bool get _open => _entry != null;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    if (_openOne == this) _openOne = null;
    super.dispose();
  }

  void _toggle() => _open ? _close() : _openPanel();

  void _close() {
    _entry?.remove();
    _entry = null;
    if (_openOne == this) _openOne = null;
    if (mounted) setState(() {});
  }

  void _openPanel() {
    _openOne?._close();
    _openOne = this;
    final overlay = Overlay.of(context);
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final screen = overlayBox?.size ?? MediaQuery.of(context).size;
    final rect = box == null
        ? Rect.fromLTWH(floatSide, 120, screen.width - floatSide * 2, 18)
        : box.localToGlobal(Offset.zero) & box.size;
    // 鸿蒙 `DDL_PANEL_W = 300`
    final w = math.min(300.0, screen.width - 16);
    final left = (rect.left - 1)
        .clamp(8.0, math.max(8.0, screen.width - w - 8))
        .toDouble();
    // 先按"标记下方"放；底下放不下就翻到标记上方（面板最高约 240）
    const panelH = 240.0;
    var top = rect.bottom + 4;
    if (top + panelH > screen.height - 8) {
      top = (rect.top - 8 - panelH)
          .clamp(8.0, math.max(8.0, screen.height - 8 - panelH))
          .toDouble();
    }
    final entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // 透明层只负责"点外面关掉"：鸿蒙的 maskColor 是透明的，没有遮罩色
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: w,
            // Overlay 里的内容不在 Material 之下 → 拿不到主题字体（会渲染成方块字），
            // 所以自己包一层透明 Material（和引导条截图同样的坑）
            child: Material(
              type: MaterialType.transparency,
              child: _DdlPanel(
                title: widget.datePrefix
                    ? '${widget.day.length > 5 ? widget.day.substring(5) : widget.day} '
                        '${minToHHmm(widget.group.minute)} 截止 · '
                        '${widget.group.todos.length} 项'
                    : '${minToHHmm(widget.group.minute)} 截止 · '
                        '${widget.group.todos.length} 项',
                group: widget.group,
                courseLabelOf: widget.courseLabelOf,
                courseColorOf: widget.courseColorOf,
                onClose: _close,
                onOpenTodo: widget.onOpenTodo == null
                    ? null
                    : (id) {
                        _close();
                        unawaited(widget.onOpenTodo!(id));
                      },
              ),
            ),
          ),
        ],
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: widget.top,
      left: 1,
      right: 1,
      child: GestureDetector(
        key: _anchor,
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // 鸿蒙 DdlMarkers 只有左/上/下内边距（右侧不缩进）
          padding: const EdgeInsets.fromLTRB(6, 1, 0, 1),
          decoration: BoxDecoration(
            // 展开时加深一档（鸿蒙：0.18 → 0.45）
            color: _open ? const Color(0x73D64545) : const Color(0x2ED64545),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: Color(0xFFFF8A8A))),
        ),
      ),
    );
  }
}

/// 截止浮层的内容（鸿蒙 `DdlExpandPanel` 逐项照抄）：标题 + ✕ / 每条待办 / 可滚动，最高 180。
class _DdlPanel extends StatelessWidget {
  final String title;
  final DdlGroup group;
  final String Function(int) courseLabelOf;
  final Color Function(int) courseColorOf;
  final VoidCallback onClose;
  final void Function(int todoId)? onOpenTodo;

  const _DdlPanel({
    required this.title,
    required this.group,
    required this.courseLabelOf,
    required this.courseColorOf,
    required this.onClose,
    this.onOpenTodo,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        // 鸿蒙 DDL_PANEL_BG = rgba(12,16,26,0.90)，圆角 GLASS_RADIUS、1px 强描边；
        // ArkUI 的 popup 自带系统阴影，这里补一层 glassSheet 的阴影才"浮"得起来
        color: const Color(0xE60C101A),
        borderRadius: BorderRadius.circular(glassRadius),
        border: Border.all(color: glassEdgeStrong),
        boxShadow: glassShadowSheet,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFFF8A8A))),
              ),
              GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Text('✕',
                      style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final t in group.todos)
                    GestureDetector(
                      onTap:
                          onOpenTodo == null ? null : () => onOpenTodo!(t.id),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            if (t.courseId > 0) ...[
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color: courseColorOf(t.courseId),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(courseLabelOf(t.courseId),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFFEAF0FA))),
                              ),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: Text(t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14, color: inkPrimary)),
                            ),
                            const SizedBox(width: 6),
                            const Text('›',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF7FA8FF))),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 待安排托盘 ----------------

/// 待安排托盘 —— 鸿蒙端 `TraySummonBar`（收起）↔ `TodoPool`（展开）。
///
/// 收起时只有一条玻璃货架：「待安排 N  展开 ▴」；点开后变成横向卡片列表：
///   标题 / 课程胶囊 / 预计 N 分钟 / ⚡ 找空档，选中 = 半透明蓝 + 亮蓝描边。
class _Tray extends StatelessWidget {
  final List<Todo> pool;
  final int page;
  final ValueChanged<int> onPage;
  final String tag;
  final int courseFilter;
  final List<String> customCategories;
  final VoidCallback onPickTag;
  final VoidCallback onPickCourse;

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
    required this.page,
    required this.onPage,
    required this.tag,
    required this.courseFilter,
    required this.customCategories,
    required this.onPickTag,
    required this.onPickCourse,
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
            Text('${pool.length}',
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
    final lessonPage = lessons.isNotEmpty && page == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              const Text('待安排',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: inkPrimary)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    lessonPage
                        ? '拖进计划；打勾完成生成待办'
                        : (selectedId > 0 ? '已选中，点空白放下' : '拖动 / 点选'),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: lessonPage
                            ? const Color(0xCCD8C48A)
                            : (selectedId > 0
                                ? accentBlue
                                : const Color(0xFF8B97AC)))),
              ),
              GestureDetector(
                key: const ValueKey('tray-toggle'),
                onTap: onToggle,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Text('收起 ▾',
                      style: TextStyle(fontSize: 12, color: Color(0xFFA9B5C9))),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              _pageChip('待办 ${pool.length}', 0,
                  key: const ValueKey('tray-page-todo')),
              if (lessons.isNotEmpty) ...[
                const SizedBox(width: 8),
                _pageChip('虚拟 ${lessons.length}', 1,
                    key: const ValueKey('tray-page-lesson')),
              ],
              const SizedBox(width: 8),
              // 鸿蒙把筛选收在「收起」下方同一行右侧：两枚小胶囊，省掉两整行高度
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!lessonPage)
                      Flexible(
                        child: _filterChip(
                          key: const ValueKey('pool-tag-filter'),
                          text: _tagText,
                          onTap: onPickTag,
                        ),
                      ),
                    if (!lessonPage) const SizedBox(width: 6),
                    Flexible(
                      child: _filterChip(
                        key: const ValueKey('pool-course-filter'),
                        text: _courseText,
                        onTap: onPickCourse,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (lessonPage)
          lessons.isEmpty
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text('没有待安排的虚拟课时。',
                      style: TextStyle(fontSize: 13, color: Color(0xFF8B97AC))),
                )
              : _lessonLayers()
        else if (pool.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text('没有待安排的事项。先去『待办』里确认几条。',
                style: TextStyle(fontSize: 14, color: Color(0xFF8B97AC))),
          )
        else
          _strip([for (final t in pool) _poolCard(t)]),
        const SizedBox(height: 10),
      ],
    );
  }

  String get _tagText {
    if (tag.isEmpty) return '全部标签';
    return categoryLabel(tag, customCategories);
  }

  String get _courseText {
    if (courseFilter < 0) return '全部课程';
    if (courseFilter == 0) return '无课程';
    for (final c in courses.values) {
      if (c.id == courseFilter) {
        return c.shortName.isNotEmpty ? c.shortName : c.name;
      }
    }
    return '全部课程';
  }

  Widget _filterChip({
    required Key key,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 24,
        padding: const EdgeInsets.only(left: 8, right: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFC3CDDE))),
            ),
            const Icon(Icons.expand_more, size: 12, color: Color(0xFF8B97AC)),
          ],
        ),
      ),
    );
  }

  Widget _pageChip(String text, int index, {required Key key}) {
    final selected = index == 0
        ? (lessons.isEmpty || page == 0)
        : (lessons.isNotEmpty && page == 1);
    return GestureDetector(
      key: key,
      onTap: () => onPage(index),
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

  /// 横向卡片条：卡片宽 140，间隔 8，左右 12（鸿蒙端 `Scroll` + `Row`）
  /// 待安排课时按课程分层（鸿蒙 `lessonGroups()`）：一门课一层，层内横排；
  /// 层数多时整区纵向滚，而不是把几十讲全部平铺成一长条。
  List<List<VirtualLesson>> get _lessonGroups {
    final byCourse = <int, List<VirtualLesson>>{};
    for (final l in lessons) {
      byCourse.putIfAbsent(l.courseId, () => []).add(l);
    }
    final keys = byCourse.keys.toList()..sort();
    return [for (final k in keys) byCourse[k]!];
  }

  Widget _lessonLayers() {
    final groups = _lessonGroups;
    final height = math.min(groups.length * 102.0, 204.0);
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: courseColorFor(courses[g.first.courseId]!),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _courseShort(g.first.courseId),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('剩 ${g.length} 讲',
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xD9D8C48A))),
                        ],
                      ),
                    ),
                    _strip([for (final l in g) _lessonCard(l)]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _courseShort(int id) {
    final c = courses[id];
    if (c == null) return '课程';
    return c.shortName.isNotEmpty ? c.shortName : c.name;
  }

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

  int _lessonDuration(VirtualLesson l) {
    final course = courses[l.courseId];
    final raw =
        l.durationMin > 0 ? l.durationMin : (course?.lessonDurationMin ?? 90);
    return ((raw / 5).round() * 5).clamp(15, 200);
  }

  /// 课时卡片上的标题（鸿蒙端 `lessonTitle`）：没起名就「课程简称 第 N 讲」
  String _lessonTitle(VirtualLesson l) =>
      lessonTitleOf(l, courses.values.toList());

  /// 小卡（鸿蒙端 glassCard）：半透明纯色 + 细边 + 投影，不使用模糊
  BoxDecoration _cardDecoration(
      {required bool selected, Color? tint, Color? edge}) {
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
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${_lessonDuration(l)} 分钟',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFD8C48A))),
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
                    color: courseColorFor(course),
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
