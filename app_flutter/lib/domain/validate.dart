// 数据合法性校验与归一化 —— 从 entry/src/main/ets/domain/Validate.ets 移植。
// 判据：shared/fixtures/validate.json。
//
// 两条原则（和鸿蒙端一样，都是被真实 bug 教出来的）：
//  1. 「合法值」只能有一个定义处；
//  2. **归一化**（normalize*，把任何输入映射到合法值）与 **校验**（validate*，只判断、
//     给一句人话）严格分开 —— 绝不在校验里偷偷改值。

import '../model/types.dart';
import 'js_compat.dart';

/// 校验结果。ok=false 时 [message] 是一句能直接显示给用户的中文。
class Validation {
  final bool ok;
  final String message;
  const Validation(this.ok, this.message);

  Map<String, dynamic> toJson() => {'ok': ok, 'message': message};

  @override
  String toString() => 'Validation($ok, "$message")';
}

const Validation _pass = Validation(true, '');

/// 待办时长下限 / 上限 / 最小分度（分钟）
const int estimateMinMin = 15;
const int estimateMaxMin = 600;
const int durationStepMin = 5;

/// 一个计划块最短 15 分钟
const int blockMinMin = 15;

const int dayMin = 24 * 60;

/// v 是否是 step 的整数倍（step <= 0 视为不成立）
bool isStepMultiple(num v, num step) {
  if (step <= 0) return false;
  return jsRound(v / step) * step == v;
}

/// 待办时长归一化：考试恒 0；其余夹进 [15,600] 并对齐 5 分钟；<=0 视为没填 → 60
int normalizeEstimate(num raw, bool isExam) {
  if (isExam) return 0;
  if (!raw.isFinite || raw <= 0) return 60;
  var v = jsRound(raw / durationStepMin) * durationStepMin;
  if (v < estimateMinMin) v = estimateMinMin;
  if (v > estimateMaxMin) v = estimateMaxMin;
  return v;
}

/// 待办时长是否合法（考试类恒合法）
Validation validateEstimate(num raw, bool isExam) {
  if (isExam) return _pass;
  if (!raw.isFinite) return const Validation(false, '时长要填一个数字');
  if (raw < estimateMinMin) return Validation(false, '时长至少 $estimateMinMin 分钟');
  if (raw > estimateMaxMin) return Validation(false, '时长最多 $estimateMaxMin 分钟');
  if (!isStepMultiple(raw, durationStepMin)) {
    return Validation(false, '时长必须是 $durationStepMin 分钟的整数倍');
  }
  return _pass;
}

bool isExamCategory(String category) => category == 'exam';

/// **旧数据迁移专用**：与 normalizeEstimate 唯一区别是**不设 600 上限**
/// （多天拆分的合计 750 分钟是合法的，夹回 600 就是"悄悄改用户的数字"）
int migrateEstimate(num raw, bool isExam) {
  if (isExam) return 0;
  if (!raw.isFinite || raw <= 0) return 60;
  var v = jsRound(raw / durationStepMin) * durationStepMin;
  if (v < estimateMinMin) v = estimateMinMin;
  return v;
}

/// 把「想要的结束分钟」收成合法值：对齐 5 分钟、至少 start+15、不越过窗口末尾。
///
/// ⚠️ 参数用 `num` 而不是 `int`：双指缩放传进来的是**小数**，先取整再算会和
/// 鸿蒙端（在函数内部才 `Math.round(desired/5)*5`）产生偏差。
int resizeEndTo(num startMin, num desiredEndMin, num windowEndMin) {
  var end = jsRound(desiredEndMin / durationStepMin) * durationStepMin;
  final floorEnd = startMin + blockMinMin;
  if (end < floorEnd) end = floorEnd.toInt();
  if (end > windowEndMin) end = windowEndMin.toInt();
  return end;
}

/// 双指缩放：开始时间不动，只按倍率拉长/压短结束时间
int pinchEnd(num startMin, num baseEndMin, num scale, num windowEndMin) {
  if (!scale.isFinite || scale <= 0) {
    return resizeEndTo(startMin, baseEndMin, windowEndMin);
  }
  final rawDur = baseEndMin - startMin;
  final baseDur = rawDur < blockMinMin ? blockMinMin : rawDur;
  return resizeEndTo(startMin, startMin + baseDur * scale, windowEndMin);
}

/// 双指缩放时屏幕中央那行提示的文案
String pinchDeltaLabel(int deltaMin) {
  if (deltaMin > 0) return '+$deltaMin min';
  if (deltaMin < 0) return '$deltaMin min';
  return '±0 min';
}

/// 一个待办所有块的时长合计；-1 = 一个块都没有（调用方据此"不回写"）
int totalBlockMinutes(List<PlanBlockLike> blocks, int todoId) {
  var total = 0;
  var any = false;
  for (final b in blocks) {
    if (b.todoId == todoId) {
      any = true;
      total += b.endMin - b.startMin;
    }
  }
  return any ? total : -1;
}

// ---------------- 不可排时段（与 ArkTS `domain/Validate.ets` 同值）----------------

/// 校验一条不可排时段：适用星期、时间范围、结束晚于开始。
Validation validateRestWindow(RestWindow w) =>
    validateRestWindowAt(w.weekday, w.startMin, w.endMin);

/// 同上，但接受任意数字 —— 三端 fixture 要把 3.5 这种非法星期也喂进来，
/// 而 [RestWindow.weekday] 是 int（会先被截断，测不出来）。
Validation validateRestWindowAt(num weekday, num startMin, num endMin) {
  if (weekday < 0 || weekday > 7 || weekday.round() != weekday) {
    return const Validation(false, '适用日期不合法');
  }
  if (!startMin.isFinite || !endMin.isFinite) {
    return const Validation(false, '时间要填成 HH:MM');
  }
  if (startMin < 0 || endMin > dayMin) {
    return const Validation(false, '时间要在 00:00–24:00 之间');
  }
  if (startMin >= endMin) {
    return const Validation(false, '结束时间必须晚于开始时间');
  }
  return const Validation(true, '');
}

/// 结束时刻的"午夜"归位：系统时间滚轮选不到 24:00，
/// 所以「结束选 00:00、而开始不是 0」按"到午夜"理解成 24:00。
int normalizeRestEnd(int pickedMin, int startMin) {
  if (pickedMin == 0 && startMin > 0) return dayMin;
  return pickedMin;
}

// ---------------- 作息表 / 时段规则 / 生成模板 / 考试时间（ArkTS 同名函数一一对应）----------------

/// 单个节次的起止时间是否合法
Validation validateSectionTime(SectionTime st) {
  if (st.section <= 0) {
    return const Validation(false, '节次编号要从 1 开始');
  }
  if (st.startMin < 0 || st.endMin > dayMin) {
    return Validation(false, '第 ${st.section} 节的时间要在 00:00–24:00 之间');
  }
  if (st.startMin >= st.endMin) {
    return Validation(false, '第 ${st.section} 节的结束时间必须晚于开始时间');
  }
  return _pass;
}

/// 整张作息表：逐条合法之外，节次编号还不能重复
Validation validateSectionTimes(List<SectionTime> sections) {
  if (sections.isEmpty) {
    return const Validation(false, '至少要有 1 个节次');
  }
  for (final st in sections) {
    final r = validateSectionTime(st);
    if (!r.ok) return r;
  }
  for (var i = 0; i < sections.length; i++) {
    for (var j = i + 1; j < sections.length; j++) {
      if (sections[i].section == sections[j].section) {
        return Validation(false, '节次编号 ${sections[i].section} 重复了');
      }
    }
  }
  return _pass;
}

SectionTime? _sectionOf(List<SectionTime> sections, int section) {
  for (final st in sections) {
    if (st.section == section) return st;
  }
  return null;
}

/// 一节课的实际起止分钟：首节次的开始 + 末节次的结束；查不到返回空数组
List<int> spanOfRule(SessionRule rule, List<SectionTime> sections) {
  final s = _sectionOf(sections, rule.startSection);
  final e = _sectionOf(sections, rule.endSection);
  if (s == null || e == null) return const [];
  return [s.startMin, e.endMin];
}

/// 时段规则是否合法（起止节次必须存在、开始不晚于结束、至少勾一周、时间落在一天内）
Validation validateSessionRule(SessionRule rule, List<SectionTime> sections) {
  if (rule.weekday < 1 || rule.weekday > 7) {
    return const Validation(false, '星期要选周一到周日');
  }
  if (rule.startSection <= 0) {
    return const Validation(false, '开始节次不合法');
  }
  if (rule.startSection > rule.endSection) {
    return const Validation(false, '开始节次不能晚于结束节次');
  }
  if (_sectionOf(sections, rule.startSection) == null) {
    return Validation(false, '作息表里没有第 ${rule.startSection} 节');
  }
  if (_sectionOf(sections, rule.endSection) == null) {
    return Validation(false, '作息表里没有第 ${rule.endSection} 节');
  }
  if (rule.weeksMask.isEmpty) {
    return const Validation(false, '周次是空的，请先设置学期总周数');
  }
  if (!rule.weeksMask.contains('1')) {
    return const Validation(false, '至少要勾选一个上课周次');
  }
  final span = spanOfRule(rule, sections);
  if (span.length < 2) {
    return const Validation(false, '这段课的时间算不出来，请检查作息表');
  }
  if (span[0] < 0 || span[1] > dayMin) {
    return const Validation(false, '这段课的时间超出了 00:00–24:00');
  }
  if (span[0] >= span[1]) {
    return const Validation(false, '这段课的结束时间必须晚于开始时间');
  }
  return _pass;
}

/// 两条时段规则的重叠（提示用，不阻断保存）
class RuleConflict {
  final int a;
  final int b;
  final int weekday;
  final int overlapStart;
  final int overlapEnd;
  const RuleConflict(
      this.a, this.b, this.weekday, this.overlapStart, this.overlapEnd);
}

bool _weeksOverlap(String ma, String mb) {
  final n = ma.length < mb.length ? ma.length : mb.length;
  for (var i = 0; i < n; i++) {
    if (ma[i] == '1' && mb[i] == '1') return true;
  }
  return false;
}

/// 找出彼此打架的时段规则：同一天、周次有交集、时间也重叠
List<RuleConflict> findRuleConflicts(
    List<SessionRule> rules, List<SectionTime> sections) {
  final out = <RuleConflict>[];
  for (var i = 0; i < rules.length; i++) {
    for (var j = i + 1; j < rules.length; j++) {
      final a = rules[i], b = rules[j];
      if (a.weekday != b.weekday) continue;
      if (!_weeksOverlap(a.weeksMask, b.weeksMask)) continue;
      final sa = spanOfRule(a, sections);
      final sb = spanOfRule(b, sections);
      if (sa.length < 2 || sb.length < 2) continue;
      final lo = sa[0] > sb[0] ? sa[0] : sb[0];
      final hi = sa[1] < sb[1] ? sa[1] : sb[1];
      if (lo < hi) out.add(RuleConflict(a.id, b.id, a.weekday, lo, hi));
    }
  }
  return out;
}

/// 生成模板标题支持的变量（与 `renderTitle` 的 8 个 replaceAll 一致）
const List<String> templateVars = ['C', 'c', 'D', 'd', 'W', 'T', 'N', 'R'];
const String templateVarHint = '%C %c %D %d %W %T %N %R';
const int templateMaxLen = 60;

class TemplateCheck {
  final bool ok;
  final String message;
  final List<String> unknown;
  const TemplateCheck(this.ok, this.message, this.unknown);
}

/// 模板标题合法性：非空、长度、每个 `%` 记号都必须是支持的变量
TemplateCheck validateTemplateTitle(String tpl) {
  final text = tpl.trim();
  if (text.isEmpty) return const TemplateCheck(false, '模板不能为空', []);
  if (text.length > templateMaxLen) {
    return TemplateCheck(false, '模板太长了（最多 $templateMaxLen 个字符）', const []);
  }
  final unknown = <String>[];
  for (var i = 0; i < text.length; i++) {
    if (text[i] != '%') continue;
    final next = i + 1 < text.length ? text[i + 1] : '';
    if (!templateVars.contains(next)) {
      final token = '%$next';
      if (!unknown.contains(token)) unknown.add(token);
    } else {
      i++; // 跳过变量字母
    }
  }
  if (unknown.isNotEmpty) {
    return TemplateCheck(false,
        '${unknown.join('、')} 不是支持的变量。可用：$templateVarHint', unknown);
  }
  return const TemplateCheck(true, '', []);
}

/// 模板截止规则参数：days 1–365、weekday 1–7
Validation validateTemplateDdl(String rule, String param) {
  if (rule == 'days') {
    final n = int.tryParse(param);
    if (n == null || n < 1 || n > 365) {
      return const Validation(false, '「N 天后」的 N 要在 1–365 之间');
    }
    return _pass;
  }
  if (rule == 'weekday') {
    final n = int.tryParse(param);
    if (n == null || n < 1 || n > 7) {
      return const Validation(false, '「指定星期几」要选周一到周日');
    }
    return _pass;
  }
  return _pass;
}

/// 考试的 [开始, 结束] 在计划视图里要落成哪一段
class ExamRange {
  final String date;
  final int startMin;
  final int endMin;
  const ExamRange(this.date, this.startMin, this.endMin);
}

/// 'HH:mm' → 分钟（解析不出来当 0；合法性由 validateExamRange 负责）
int _hhmmToMin(String s) {
  final h = int.tryParse(s.substring(0, 2)) ?? 0;
  final m = int.tryParse(s.substring(3, 5)) ?? 0;
  return h * 60 + m;
}

/// 考试时间范围：开始/结束都得填、必须同一天、结束晚于开始
Validation validateExamRange(String start, String end) {
  if (start.length < 16 || end.length < 16) {
    return const Validation(false, '考试的开始和结束时间都要选');
  }
  if (start.substring(0, 10) != end.substring(0, 10)) {
    return const Validation(false, '考试的开始和结束要在同一天');
  }
  final s = _hhmmToMin(start.substring(11, 16));
  final e = _hhmmToMin(end.substring(11, 16));
  if (e <= s) {
    return const Validation(false, '考试的结束时间必须晚于开始时间');
  }
  return _pass;
}

ExamRange examRangeOf(String start, String end) => ExamRange(
    start.substring(0, 10),
    _hhmmToMin(start.substring(11, 16)),
    _hhmmToMin(end.substring(11, 16)));
