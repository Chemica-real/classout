// 计划视图的纯算术 —— 从鸿蒙端 entry/src/main/ets/domain/PlanMath.ets **逐函数手工移植**。
//
// ⚠️ 移植约定：**不许"顺手优化"**。这里的每个函数都必须和鸿蒙端算得一模一样，
//    判据是 shared/fixtures/plan_math.json（122 条用例，测试见 test/fixtures_test.dart）。
//    鸿蒙端那条规则要是改了，先改 fixtures 再改这里，别直接改这里。
//
// ⚠️ 两个 JS 兼容闸门：ArkTS 的 `Math.round` / `parseInt` 和 Dart 的同名函数在
//    边界上不一致（负数取整方向、字符串前缀解析），所以用 _jsRound / _jsParseInt 复刻。
//    测试里 snap(-8) 这类用例就是在盯这个。

import '../model/types.dart';

// ---------------- 常量 ----------------

const int snapMin = 15;
const int vpPerMin = 1;
const int minBlockMin = snapMin;
const int hourMin = 60;

const int windowMinStart = 0;
const int windowMaxEnd = 24 * 60;
const int windowMinSpan = 60;
const int windowSnapMin = 30;

// ---------------- JS 兼容闸门 ----------------

/// 等价于 JS `Math.round`：.5 一律向 **+∞** 取整（Dart 的 `round()` 是远离零）。
int _jsRound(num x) => (x + 0.5).floor();

/// 等价于 JS `parseInt(s, 10)`：解析**前缀**数字，失败返回 null（Dart 的 `int.parse` 不接受尾巴）。
int? _jsParseInt(String s) {
  final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}

int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

// ---------------- 时间窗 ----------------

class TimeWindow {
  final int startMin;
  final int endMin;
  const TimeWindow(this.startMin, this.endMin);

  factory TimeWindow.fromJson(Map<String, dynamic> j) =>
      TimeWindow(_asInt(j['startMin']), _asInt(j['endMin']));

  Map<String, dynamic> toJson() => {'startMin': startMin, 'endMin': endMin};

  @override
  bool operator ==(Object other) =>
      other is TimeWindow && other.startMin == startMin && other.endMin == endMin;

  @override
  int get hashCode => Object.hash(startMin, endMin);

  @override
  String toString() => 'TimeWindow($startMin, $endMin)';
}

int _asInt(Object? v) => v is num ? v.toInt() : 0;

const TimeWindow defaultWindow = TimeWindow(7 * 60, 24 * 60);

/// 吸附到 15 分钟刻度
int snap(int v) => _jsRound(v / snapMin) * snapMin;

int _snapTo(int v, int step) => _jsRound(v / step) * step;

/// 合法的时间窗：吸附到 30 分钟并夹进可用范围（不足 1 小时就撑到 1 小时）
TimeWindow normalizeWindow(TimeWindow w) {
  var s = _clamp(_snapTo(w.startMin, windowSnapMin), windowMinStart,
      windowMaxEnd - windowMinSpan);
  var e = _clamp(_snapTo(w.endMin, windowSnapMin), windowMinStart + windowMinSpan,
      windowMaxEnd);
  if (e - s < windowMinSpan) {
    s = e - windowMinSpan;
    if (s < windowMinStart) {
      s = windowMinStart;
      e = s + windowMinSpan;
    }
  }
  return TimeWindow(s, e);
}

/// 对齐到整半小时网格 —— 目前就是 normalizeWindow（鸿蒙端如此，保持字面一致）
TimeWindow alignWindow(TimeWindow w) => normalizeWindow(w);

/// 时间窗 → 存库字符串（`'start,end'`，分钟）
String formatWindow(TimeWindow w) {
  final n = normalizeWindow(w);
  return '${n.startMin},${n.endMin}';
}

/// 存库字符串 → 时间窗；解析不出来 / 空串退回默认窗
TimeWindow parseWindow(String raw) {
  final parts = raw.split(',');
  if (parts.length != 2) return defaultWindow;
  final s = _jsParseInt(parts[0]);
  final e = _jsParseInt(parts[1]);
  if (s == null || e == null) return defaultWindow;
  return normalizeWindow(TimeWindow(s, e));
}

/// 时间轴：画哪一段、多高、刻度在哪。
/// 不变式（鸿蒙端 test.ts 有断言，这里同样要守）：
///   `(marks.length - 1) * hourMin < height() <= marks.length * hourMin`
class TimeAxis {
  final int startMin;
  final int endMin;
  final List<int> marks;

  TimeAxis._(this.startMin, this.endMin, this.marks);

  factory TimeAxis(TimeWindow w) {
    final n = alignWindow(w);
    final m = <int>[];
    for (var t = n.startMin; t < n.endMin; t += hourMin) {
      m.add(t);
    }
    return TimeAxis._(n.startMin, n.endMin, m);
  }

  int height() => (endMin - startMin) * vpPerMin;

  int yToMinute(int y) => _clamp(snap(startMin + (y ~/ vpPerMin)), startMin, endMin);

  int minuteToY(int min) => (min - startMin) * vpPerMin;

  bool contains(int min) => min >= startMin && min <= endMin;
}

// ---------------- 时长 ----------------

int durationToH(int min) => min * vpPerMin;

/// 规范化时长：<=0 视为 60；下限 15 分钟；**不**吸附到 15 的倍数
int normalizeDuration(int min) {
  if (min <= 0) return 60;
  return min < minBlockMin ? minBlockMin : min;
}

/// 对半分：两块都在 5 分钟刻度上，且**和严格等于** total；拆不动返回空
List<int> halveMinutes(int total) {
  if (total < 10) return <int>[];
  final half = (total / 2 / 5).floor() * 5;
  final first = half < 5 ? 5 : half;
  final second = total - first;
  if (second < 5) return <int>[];
  return <int>[first, second];
}

/// 把时长 durationMin 的块放到 y 处 → [start, end]
List<int> dropRange(TimeAxis axis, int y, int durationMin) {
  final dur = normalizeDuration(durationMin);
  var start = axis.yToMinute(y);
  if (start + dur > axis.endMin) start = axis.endMin - dur;
  if (start < axis.startMin) start = axis.startMin;
  return <int>[start, start + dur];
}

/// 竖直拖动：时长不变，整体平移并夹在窗口内
List<int> moveRange(TimeAxis axis, int startMin, int endMin, int deltaY) {
  final dur = endMin - startMin;
  final start = _clamp(snap(startMin + (deltaY ~/ vpPerMin)), axis.startMin,
      axis.endMin - dur);
  return <int>[start, start + dur];
}

/// 拖底边：起点不动，最短 15 分钟，最晚到窗口末尾
List<int> resizeRange(TimeAxis axis, int startMin, int endMin, int deltaY) {
  final end = _clamp(snap(endMin + (deltaY ~/ vpPerMin)), startMin + minBlockMin,
      axis.endMin);
  return <int>[startMin, end];
}

/// 两个区间是否重叠（半开区间）
bool overlaps(int aStart, int aEnd, int bStart, int bEnd) =>
    aStart < bEnd && bStart < aEnd;

/// 某个待办的全部时间块是否都完成（没有块 → false）
bool allBlocksDone(List<PlanBlock> blocks, int todoId) {
  var any = false;
  for (final b in blocks) {
    if (b.todoId == todoId) {
      any = true;
      if (!b.done) return false;
    }
  }
  return any;
}

// ---------------- 待安排托盘 ----------------

/// 同一天不允许出现第二块（跨天拆块仍允许）
bool hasBlockOnDate(List<PlanBlock> blocks, int todoId, String date) {
  for (final b in blocks) {
    if (b.todoId == todoId && b.date == date) return true;
  }
  return false;
}

/// 已经排在哪几天（升序去重）
List<String> scheduledDays(List<PlanBlock> blocks, int todoId) {
  final set = <String>{};
  for (final b in blocks) {
    if (b.todoId == todoId) set.add(b.date);
  }
  final out = set.toList();
  out.sort();
  return out;
}

/// 待安排 = 未完成（active）且还没排进任何一块
List<Todo> selectPoolTodos(List<Todo> todos, List<PlanBlock> blocks) {
  final scheduled = <int>{};
  for (final b in blocks) {
    if (b.todoId > 0) scheduled.add(b.todoId);
  }
  final out = <Todo>[];
  for (final t in todos) {
    if (t.status == TodoStatus.active && !scheduled.contains(t.id)) out.add(t);
  }
  return out;
}

/// 托盘排序：有截止的在前（按 ddl 升序）、同 ddl 按 id 升序；无截止的排最后
List<Todo> sortPoolTodos(List<Todo> todos) {
  final out = List<Todo>.from(todos);
  out.sort((a, b) {
    final aHas = a.ddl.isNotEmpty;
    final bHas = b.ddl.isNotEmpty;
    if (aHas && bHas) {
      if (a.ddl != b.ddl) return a.ddl.compareTo(b.ddl);
      return a.id - b.id;
    }
    if (aHas) return -1;
    if (bHas) return 1;
    return a.id - b.id;
  });
  return out;
}

// ---------------- 截止标记分组 ----------------

class DdlGroup {
  final int minute;
  final List<Todo> todos;
  const DdlGroup(this.minute, this.todos);
}

/// 'YYYY-MM-DD HH:mm' → 当天分钟数；没有时刻 / 解析不出 → -1
int ddlMinuteOf(String ddl) {
  if (ddl.length < 16) return -1;
  final h = _jsParseInt(ddl.substring(11, 13));
  final m = _jsParseInt(ddl.substring(14, 16));
  if (h == null || m == null) return -1;
  return h * 60 + m;
}

/// 某天的截止按分钟分组（组按分钟升序、组内按 id 升序）。
///
/// 规则（与鸿蒙端逐条一致）：
/// - 只收未完成（done / archived 都不算）；
/// - **「考试」不算截止**（它的 ddl 存的是开始时刻）；
/// - ddl 的日期部分必须等于 date；
/// - 只有日期没有时刻的丢掉；
/// - 早于轴起点夹到起点、晚于轴终点夹到终点（时间窗可改，不夹会画到网格外）。
List<DdlGroup> ddlGroupsOn(List<Todo> todos, String date, int axisStartMin,
    [int axisEndMin = windowMaxEnd]) {
  final buckets = <int, List<Todo>>{};
  for (final t in todos) {
    if (t.status == TodoStatus.done || t.status == TodoStatus.archived) continue;
    if (t.category == TodoCategory.exam) continue;
    if (t.ddl.substring(0, t.ddl.length < 10 ? t.ddl.length : 10) != date) continue;
    final raw = ddlMinuteOf(t.ddl);
    if (raw < 0) continue;
    var minute = raw < axisStartMin ? axisStartMin : raw;
    if (minute > axisEndMin) minute = axisEndMin;
    buckets.putIfAbsent(minute, () => <Todo>[]).add(t);
  }
  final out = <DdlGroup>[];
  for (final entry in buckets.entries) {
    final sorted = List<Todo>.from(entry.value)..sort((a, b) => a.id - b.id);
    out.add(DdlGroup(entry.key, sorted));
  }
  out.sort((a, b) => a.minute - b.minute);
  return out;
}
