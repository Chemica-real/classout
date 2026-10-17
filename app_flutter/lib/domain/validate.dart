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
  if (!scale.isFinite || scale <= 0)
    return resizeEndTo(startMin, baseEndMin, windowEndMin);
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
