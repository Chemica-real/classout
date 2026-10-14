/**
 * 数据合法性校验与归一化（纯函数）
 *
 * 为什么单独一个模块：这些规则要在**写库之前**和**已有数据的体检**里用同一份实现，
 * 而且它们不碰鸿蒙 API，可以进 tools/domain-check 离线断言。
 *
 * 两条原则（都是被真实 bug 教出来的）：
 *  1. 「合法值」只能有一个定义处。UI 里再写一遍 `>= 15` 迟早会漂。
 *  2. 「归一化」和「校验」分开：
 *     - normalize* 把任何输入映射到合法值（用于旧数据迁移、失焦提交）；
 *     - validate* 只判断并给出人话提示（用于表单即时反馈）。
 *     绝不在校验里偷偷改值 —— 上一版把用户填的 20 分钟悄悄改成 15，被用户抓到过。
 */

import { PlanBlock, RestWindow, SectionTime, SessionRule, TodoCategory } from '../model/Types';

// ---------------- 通用 ----------------

/** 校验结果。ok 为 false 时 message 是一句能直接显示给用户的中文。 */
export interface Validation {
  ok: boolean;
  message: string;
}

function pass(): Validation {
  return { ok: true, message: '' };
}

function fail(message: string): Validation {
  return { ok: false, message: message };
}

/** v 是否是 step 的整数倍（step <= 0 时视为不成立） */
export function isStepMultiple(v: number, step: number): boolean {
  if (step <= 0) {
    return false;
  }
  return Math.round(v / step) * step === v;
}

// ---------------- 待办时长 ----------------

/** 待办时长下限（分钟） */
export const ESTIMATE_MIN_MIN: number = 15;
/** 待办时长上限（分钟） */
export const ESTIMATE_MAX_MIN: number = 600;
/** 待办时长与计划块时长共用的最小分度（分钟） */
export const DURATION_STEP_MIN: number = 5;

/**
 * 待办时长归一化。
 *
 * 规则（用户 2026-10-14 拍定）：
 *  - 考试类待办的「预计耗时」没有意义，恒为 0（这是唯一的 0 豁免）；
 *  - 其余一律夹进 [15, 600]，并**对齐到最近的 5 分钟**；
 *  - 非数字/<=0 视为「没填」，取默认 60（与 PlanMath.normalizeDuration 保持一致）。
 *
 * 旧数据里 20 / 23 / 7 这类值靠这个函数静默搬到合法值（见 TodoRepo.normalizeAllEstimates）。
 */
export function normalizeEstimate(raw: number, isExam: boolean): number {
  if (isExam) {
    return 0;
  }
  if (!Number.isFinite(raw) || raw <= 0) {
    return 60;
  }
  let v: number = Math.round(raw / DURATION_STEP_MIN) * DURATION_STEP_MIN;
  if (v < ESTIMATE_MIN_MIN) {
    v = ESTIMATE_MIN_MIN;
  }
  if (v > ESTIMATE_MAX_MIN) {
    v = ESTIMATE_MAX_MIN;
  }
  return v;
}

/** 待办时长是否合法（考试类恒合法） */
export function validateEstimate(raw: number, isExam: boolean): Validation {
  if (isExam) {
    return pass();
  }
  if (!Number.isFinite(raw)) {
    return fail('时长要填一个数字');
  }
  if (raw < ESTIMATE_MIN_MIN) {
    return fail(`时长至少 ${ESTIMATE_MIN_MIN} 分钟`);
  }
  if (raw > ESTIMATE_MAX_MIN) {
    return fail(`时长最多 ${ESTIMATE_MAX_MIN} 分钟`);
  }
  if (!isStepMultiple(raw, DURATION_STEP_MIN)) {
    return fail(`时长必须是 ${DURATION_STEP_MIN} 分钟的整数倍`);
  }
  return pass();
}

/** 某个分类的待办是不是考试类 */
export function isExamCategory(category: string): boolean {
  return category === TodoCategory.Exam;
}

/**
 * **旧数据迁移专用**的时长归一化。
 *
 * 与 `normalizeEstimate` 的唯一区别：**不设 600 上限**。
 *
 * 为什么必须分开：600 是「手动输入」的约束，而多天拆分的**合计**是推导出来的 ——
 * 5 天各 2.5 小时 = 750 分钟是完全合法的状态。
 * 若启动时那次迁移把它夹回 600，用户下次打开就会发现自己填的时长被悄悄改小了，
 * 而这正是本项目被用户抓到过的那类 bug（"悄悄改我的数字"）。
 */
export function migrateEstimate(raw: number, isExam: boolean): number {
  if (isExam) {
    return 0;
  }
  if (!Number.isFinite(raw) || raw <= 0) {
    return 60;
  }
  let v: number = Math.round(raw / DURATION_STEP_MIN) * DURATION_STEP_MIN;
  if (v < ESTIMATE_MIN_MIN) {
    v = ESTIMATE_MIN_MIN;
  }
  return v;
}

// ---------------- 计划块的时长与双指缩放 ----------------

/** 一个计划块最短 15 分钟 */
export const BLOCK_MIN_MIN: number = 15;

/**
 * 把「想要的结束分钟」收成合法值：对齐到 5 分钟分度，至少 start+15，不越过窗口末尾。
 *
 * 双指缩放和「±5 分钟」按钮都走这一个函数，保证分度只有一处定义。
 *
 * ⚠️ 前提：调用方保证 `startMin <= windowEndMin - BLOCK_MIN_MIN`。
 * 真到不了（起手位置离窗口末尾不足 15 分钟）时**窗口上限优先** ——
 * 宁可让块短一点，也不能画到网格外面去。摆放/拖动都夹紧了起点，所以正常路径不会碰到。
 */
export function resizeEndTo(startMin: number, desiredEndMin: number, windowEndMin: number): number {
  let end: number = Math.round(desiredEndMin / DURATION_STEP_MIN) * DURATION_STEP_MIN;
  const floorEnd: number = startMin + BLOCK_MIN_MIN;
  if (end < floorEnd) {
    end = floorEnd;
  }
  if (end > windowEndMin) {
    end = windowEndMin;
  }
  return end;
}

/**
 * 双指缩放：**开始时间不动**，只按倍率把结束时间往下拉长/往上压短。
 *
 * @param startMin     块的开始分钟（不变的锚点）
 * @param baseEndMin   按下双指那一刻的结束分钟（缩放的基准，不是当前值）
 * @param scale        累计缩放倍率（>1 变长，<1 变短）
 * @param windowEndMin 时间窗末尾
 */
export function pinchEnd(startMin: number, baseEndMin: number, scale: number,
  windowEndMin: number): number {
  if (!Number.isFinite(scale) || scale <= 0) {
    return resizeEndTo(startMin, baseEndMin, windowEndMin);
  }
  const baseDur: number = Math.max(BLOCK_MIN_MIN, baseEndMin - startMin);
  return resizeEndTo(startMin, startMin + baseDur * scale, windowEndMin);
}

/** 双指缩放时屏幕中央那行提示的文案 */
export function pinchDeltaLabel(deltaMin: number): string {
  if (deltaMin > 0) {
    return `+${deltaMin} min`;
  }
  if (deltaMin < 0) {
    return `${deltaMin} min`;
  }
  return '±0 min';
}

/**
 * 一个待办所有块的时长合计（分钟）。
 *
 * 返回 -1 = 该待办当前**一个块都没有**。调用方据此决定「不回写」——
 * 否则删光块会把待办时长抹成 0（用户看到的会是「预计 0 分钟」）。
 */
export function totalBlockMinutes(blocks: PlanBlock[], todoId: number): number {
  let total: number = 0;
  let any: boolean = false;
  for (const b of blocks) {
    if (b.todoId === todoId) {
      any = true;
      total += b.endMin - b.startMin;
    }
  }
  return any ? total : -1;
}

// ---------------- 作息（节次时间） ----------------

export const DAY_MIN: number = 24 * 60;

function hasSection(sections: SectionTime[], section: number): boolean {
  for (const s of sections) {
    if (s.section === section) {
      return true;
    }
  }
  return false;
}

function sectionStart(sections: SectionTime[], section: number): number {
  for (const s of sections) {
    if (s.section === section) {
      return s.startMin;
    }
  }
  return -1;
}

function sectionEnd(sections: SectionTime[], section: number): number {
  for (const s of sections) {
    if (s.section === section) {
      return s.endMin;
    }
  }
  return -1;
}

/** 单个节次的起止时间是否合法 */
export function validateSectionTime(st: SectionTime): Validation {
  if (!Number.isFinite(st.section) || st.section <= 0) {
    return fail('节次编号要从 1 开始');
  }
  if (st.startMin < 0 || st.endMin > DAY_MIN) {
    return fail(`第 ${st.section} 节的时间要在 00:00–24:00 之间`);
  }
  if (st.startMin >= st.endMin) {
    return fail(`第 ${st.section} 节的结束时间必须晚于开始时间`);
  }
  return pass();
}

/** 整张作息表：逐条合法之外，节次编号还不能重复 */
export function validateSectionTimes(sections: SectionTime[]): Validation {
  if (sections.length === 0) {
    return fail('至少要有 1 个节次');
  }
  for (const st of sections) {
    const r: Validation = validateSectionTime(st);
    if (!r.ok) {
      return r;
    }
  }
  for (let i = 0; i < sections.length; i++) {
    for (let j = i + 1; j < sections.length; j++) {
      if (sections[i].section === sections[j].section) {
        return fail(`节次编号 ${sections[i].section} 重复了`);
      }
    }
  }
  return pass();
}

// ---------------- 课程时段规则 ----------------

/**
 * 一节课的实际起止分钟：由首节次的开始 + 末节次的结束推出。
 * 作息表里查不到对应节次时返回空数组（调用方当作不合法）。
 */
export function spanOfRule(rule: SessionRule, sections: SectionTime[]): number[] {
  const s: number = sectionStart(sections, rule.startSection);
  const e: number = sectionEnd(sections, rule.endSection);
  if (s < 0 || e < 0) {
    return [];
  }
  return [s, e];
}

/**
 * 时段规则是否合法。
 *
 * 这是「课程始末时间正确性」的落点：起止节次必须存在、开始不得晚于结束、
 * 周次掩码至少要勾一周，并且算出来的实际上课时间要落在一天之内。
 */
export function validateSessionRule(rule: SessionRule, sections: SectionTime[]): Validation {
  if (rule.weekday < 1 || rule.weekday > 7) {
    return fail('星期要选周一到周日');
  }
  if (rule.startSection <= 0) {
    return fail('开始节次不合法');
  }
  if (rule.startSection > rule.endSection) {
    return fail('开始节次不能晚于结束节次');
  }
  if (!hasSection(sections, rule.startSection)) {
    return fail(`作息表里没有第 ${rule.startSection} 节`);
  }
  if (!hasSection(sections, rule.endSection)) {
    return fail(`作息表里没有第 ${rule.endSection} 节`);
  }
  if (rule.weeksMask.length === 0) {
    return fail('周次是空的，请先设置学期总周数');
  }
  if (rule.weeksMask.indexOf('1') < 0) {
    return fail('至少要勾选一个上课周次');
  }
  const span: number[] = spanOfRule(rule, sections);
  if (span.length < 2) {
    return fail('这段课的时间算不出来，请检查作息表');
  }
  if (span[0] < 0 || span[1] > DAY_MIN) {
    return fail('这段课的时间超出了 00:00–24:00');
  }
  if (span[0] >= span[1]) {
    return fail('这段课的结束时间必须晚于开始时间');
  }
  return pass();
}

/** 两条时段规则的重叠情况 */
export interface RuleConflict {
  /** 规则 id（用来定位） */
  a: number;
  b: number;
  weekday: number;
  overlapStart: number;
  overlapEnd: number;
}

function weeksOverlap(ma: string, mb: string): boolean {
  const n: number = Math.min(ma.length, mb.length);
  for (let i = 0; i < n; i++) {
    if (ma.charAt(i) === '1' && mb.charAt(i) === '1') {
      return true;
    }
  }
  return false;
}

/**
 * 找出彼此打架的时段规则：同一天、周次有交集、时间也重叠。
 *
 * 这是**提示**不是阻断 —— 用户可能故意让两门课重合（比如"同一时段两门任选"），
 * 所以只把它列出来给用户看，不拦着保存。
 */
export function findRuleConflicts(rules: SessionRule[], sections: SectionTime[]): RuleConflict[] {
  const out: RuleConflict[] = [];
  for (let i = 0; i < rules.length; i++) {
    for (let j = i + 1; j < rules.length; j++) {
      const a: SessionRule = rules[i];
      const b: SessionRule = rules[j];
      if (a.weekday !== b.weekday) {
        continue;
      }
      if (!weeksOverlap(a.weeksMask, b.weeksMask)) {
        continue;
      }
      const sa: number[] = spanOfRule(a, sections);
      const sb: number[] = spanOfRule(b, sections);
      if (sa.length < 2 || sb.length < 2) {
        continue;
      }
      const lo: number = sa[0] > sb[0] ? sa[0] : sb[0];
      const hi: number = sa[1] < sb[1] ? sa[1] : sb[1];
      if (lo < hi) {
        out.push({ a: a.id, b: b.id, weekday: a.weekday, overlapStart: lo, overlapEnd: hi });
      }
    }
  }
  return out;
}

// ---------------- 生成模板（自动生成待办） ----------------

/**
 * 标题模板里支持的变量。**必须和 `domain/TodoGenerator.renderTitle` 的实现一致**
 *（那边用 8 个手写的 replaceAll，不认正则）。
 */
export const TEMPLATE_VARS: string[] = ['C', 'c', 'D', 'd', 'W', 'T', 'N', 'R'];

/** 给用户看的变量清单（配合下面的快捷插入按钮） */
export const TEMPLATE_VAR_HINT: string = '%C %c %D %d %W %T %N %R';

/** 模板标题长度上限（字符） */
export const TEMPLATE_MAX_LEN: number = 60;

/** 模板标题的校验结果 */
export interface TemplateCheck {
  ok: boolean;
  message: string;
  /** 不被支持的 `%X` 记号（已去重），供 UI 高亮 */
  unknown: string[];
}

/**
 * 模板标题合法性：非空、长度、以及**每一个 `%` 记号都必须是支持的变量**。
 *
 * 为什么非要查未知变量：渲染用的是手写 replaceAll，不认识的 `%M` 会**原样留在标题里**，
 * 用户要等下次下课、在待办列表里看到「%M作业」才发现写错了。
 * 与其事后困惑，不如保存时就拦住 —— 这正是用户要的"输入合法性检验，防止错误"。
 *
 * 注意 `%%` 也会被判为不支持：渲染层没有转义语法，与其让用户以为能转义，不如直接说清楚。
 */
export function validateTemplateTitle(tpl: string): TemplateCheck {
  const text: string = tpl.trim();
  if (text.length === 0) {
    return { ok: false, message: '模板不能为空', unknown: [] };
  }
  if (text.length > TEMPLATE_MAX_LEN) {
    return {
      ok: false,
      message: `模板太长了（最多 ${TEMPLATE_MAX_LEN} 个字符）`,
      unknown: []
    };
  }
  const unknown: string[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text.charAt(i) !== '%') {
      continue;
    }
    const next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
    if (TEMPLATE_VARS.indexOf(next) < 0) {
      const token: string = `%${next}`;
      if (unknown.indexOf(token) < 0) {
        unknown.push(token);
      }
    } else {
      i++;   // 跳过变量字母，别把它当成下一个 '%' 的候选
    }
  }
  if (unknown.length > 0) {
    return {
      ok: false,
      message: `${unknown.join('、')} 不是支持的变量。可用：${TEMPLATE_VAR_HINT}`,
      unknown: unknown
    };
  }
  return { ok: true, message: '', unknown: [] };
}

/**
 * 生成模板的截止规则参数合法性。
 * `days` 要 1–365；`weekday` 要 1–7（周一..周日）；其余规则不带参数。
 */
export function validateTemplateDdl(rule: string, param: string): Validation {
  if (rule === 'days') {
    const n: number = Number.parseInt(param, 10);
    if (Number.isNaN(n) || n < 1 || n > 365) {
      return fail('「N 天后」的 N 要在 1–365 之间');
    }
    return pass();
  }
  if (rule === 'weekday') {
    const n: number = Number.parseInt(param, 10);
    if (Number.isNaN(n) || n < 1 || n > 7) {
      return fail('「指定星期几」要选周一到周日');
    }
    return pass();
  }
  return pass();
}

// ---------------- 不可排时段 ----------------

/** 休息时段（不可排）是否合法 */
export function validateRestWindow(w: RestWindow): Validation {
  if (w.weekday < 0 || w.weekday > 7 || Math.round(w.weekday) !== w.weekday) {
    return fail('适用日期不合法');
  }
  if (!Number.isFinite(w.startMin) || !Number.isFinite(w.endMin)) {
    return fail('时间要填成 HH:MM');
  }
  if (w.startMin < 0 || w.endMin > DAY_MIN) {
    return fail('时间要在 00:00–24:00 之间');
  }
  if (w.startMin >= w.endMin) {
    return fail('结束时间必须晚于开始时间');
  }
  return pass();
}

// ---------------- 考试的时间范围 ----------------

/**
 * 考试的 [开始, 结束] 在计划视图里要落成哪一段。
 * `date` 取开始那天（跨天的考试不合法，见 validateExamRange）。
 */
export interface ExamRange {
  date: string;
  startMin: number;
  endMin: number;
}

/** 'HH:mm' → 分钟数（解析不出来当 0；合法性由 validateExamRange 负责） */
function hhmmToMin(s: string): number {
  const h: number = parseInt(s.substring(0, 2), 10);
  const m: number = parseInt(s.substring(3, 5), 10);
  return (Number.isNaN(h) ? 0 : h) * 60 + (Number.isNaN(m) ? 0 : m);
}

/**
 * 考试时间范围是否合法（用户 2026-10-14：「考试应该不同于作业等，他有固定的时间范围」）。
 *
 * 规则：开始/结束都得填、**必须同一天**、结束要晚于开始。
 * 「同一天」这条是刻意的：跨天的考试排成一块会横跨两天，而计划块只有 `date + start/end 分钟`，
 * 表达不了跨天（要表达就得把块拆成两段，那是另一个功能）。真遇到就提示用户分两天记。
 */
export function validateExamRange(start: string, end: string): Validation {
  if (start.length < 16 || end.length < 16) {
    return fail('考试的开始和结束时间都要选');
  }
  if (start.substring(0, 10) !== end.substring(0, 10)) {
    return fail('考试的开始和结束要在同一天');
  }
  const s: number = hhmmToMin(start.substring(11, 16));
  const e: number = hhmmToMin(end.substring(11, 16));
  if (e <= s) {
    return fail('考试的结束时间必须晚于开始时间');
  }
  return pass();
}

/** 由考试的起止时刻算出计划块要排在哪一天、哪一段（调用前先过 validateExamRange） */
export function examRangeOf(start: string, end: string): ExamRange {
  return {
    date: start.substring(0, 10),
    startMin: hhmmToMin(start.substring(11, 16)),
    endMin: hhmmToMin(end.substring(11, 16))
  };
}
