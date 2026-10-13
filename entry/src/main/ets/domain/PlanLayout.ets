/**
 * 计划页的版式常量与**列几何**（纯函数）
 *
 * 为什么单独一个模块：
 *  1. 这些数字以前散在 `PlanDayView.ets` 里，而 `tools/domain-check/test.ts` 只能把它们
 *     **再抄一遍**再断言（注释写着"这些数字必须和 PlanDayView 里的保持一致"）。
 *     抄一遍的断言发现不了漂移 —— 现在两边都 import 这一份，漂移在编译期就报错。
 *  2. 三日视图要靠这套列算术（列宽 / 列 x / 命中哪一列 / 三天是哪三天），
 *     纯函数才能离线断言（拖拽跨天没法在真机上反复试）。
 *
 * ⚠️ 布局约定：`viewportW` / `x` 都是 **vp**（ArkUI 的 Area/width 与事件坐标都是 vp）。
 *    `tools/plan-state.py` 那边看到的是 px，别混。
 */

import { addDays, formatDate, parseDate, WEEKDAY_CN, weekdayOf } from '../util/DateUtil';

// ---------------- 时间轴与列 ----------------

/**
 * 左侧时间轴的宽度（vp）：刻度文字 40 + 与网格线之间的间隙 6。
 * 所有"从时间轴右边起画"的元素都用它做 x。
 */
export const AXIS_W: number = 46;

/** 单日视图的列数 */
export const COLS_DAY: number = 1;
/** 三日视图的列数 */
export const COLS_THREE: number = 3;

/**
 * 一个块的**最小视觉高度**（vp），不是最短时长。
 *
 * ⚠️ 这里踩过两次坑，别再改：
 *   1. 最初把分钟常量 `MIN_BLOCK_MIN` 当 vp 用（预览 15vp、松手 13vp），前后不一致；
 *   2. 后来改成"装得下标题+副文字"的高度（46vp）—— 但 **1 分钟 = 1vp 是全项目约定**，
 *      给 15 分钟的块画 46vp 会让它盖住后面 31 分钟、把那些时段点不到。
 * 正确做法是**内容适配块高**（紧凑排版），不是块高适配内容。
 * 这个常量只用来防止拖动时块塌成不可见。
 */
export const MIN_VISIBLE_H: number = 6;

/** 时间轴一格的跨度（分钟）。每个刻度代表它**后面**这 60 分钟。 */
export const HOUR_MIN: number = 60;

// ---------------- 字号档位 ----------------

/**
 * 计划页的一档字号。
 *
 * 背景：字号试版话题**已由用户关闭**（PLAN_REDESIGN §7.3），所以不再保留
 * `LAYOUT_A/B/C/D` 四个开关，只留当前生效的这一档（原来的 LAYOUT_C）。
 * 各字段含义：
 *   title  = 网格里块标题（待办/课时）
 *   sub    = 块副文字（时间范围 · 课程）
 *   hour   = 时间轴刻度
 *   tray   = 待安排格 / 列头里的文字
 *   cardSub= 次级说明文字（"预计 N 分钟"、提示胶囊等）
 *   chip   = 编辑窗标题等
 *   compact= 短块（放不下两行时）用的紧凑字号
 */
export class LayoutSpec {
  title: number;
  sub: number;
  hour: number;
  tray: number;
  cardSub: number;
  chip: number;
  compact: number;

  constructor(title: number, sub: number, hour: number, tray: number,
    cardSub: number, chip: number, compact: number) {
    this.title = title;
    this.sub = sub;
    this.hour = hour;
    this.tray = tray;
    this.cardSub = cardSub;
    this.chip = chip;
    this.compact = compact;
  }
}

/** 当前生效的字号档（原 LAYOUT_C，随手选中，不要重新开这个话题） */
export const LAYOUT: LayoutSpec = new LayoutSpec(14, 11, 12, 14, 12, 14, 10);

/** 紧凑块的最小高度：文字的行高（不是时长） */
export function compactMinH(): number {
  return Math.ceil(LAYOUT.compact * 1.4);
}

/** 块高度小于此值时改用紧凑排版（单行：标题 + 时间，去掉完成圆圈） */
export function compactThreshold(): number {
  return Math.ceil(LAYOUT.title * 1.35) + Math.ceil(LAYOUT.sub * 1.35);
}

// ---------------- 列几何 ----------------

/** 内容区总宽（vp）= 视口宽 − 时间轴。视口太窄时夹到 0，绝不返回负数 */
export function contentWidth(viewportW: number): number {
  const w: number = viewportW - AXIS_W;
  return w > 0 ? w : 0;
}

/** 每列宽（vp）。列数非正时返回 0 */
export function columnWidth(viewportW: number, count: number): number {
  if (count <= 0) {
    return 0;
  }
  return contentWidth(viewportW) / count;
}

/** 第 index 列的左边缘 x（vp，网格内容坐标，已含时间轴偏移） */
export function columnX(viewportW: number, count: number, index: number): number {
  return AXIS_W + columnWidth(viewportW, count) * index;
}

/**
 * 命中测试：网格内容坐标 x（vp）落在第几列。
 * 返回 -1 = 落在时间轴上、或超出网格右边（调用方据此"不改天"）。
 */
export function columnAtX(viewportW: number, count: number, x: number): number {
  if (count <= 0) {
    return -1;
  }
  const w: number = columnWidth(viewportW, count);
  if (w <= 0) {
    return -1;
  }
  // 不额外写 `x < AXIS_W` 的守卫：下面的 i < 0 已经覆盖了它
  //（变异测试确认过那条守卫是冗余的 —— 冗余分支测不出来，就别留）
  const i: number = Math.floor((x - AXIS_W) / w);
  if (i < 0 || i >= count) {
    return -1;
  }
  return i;
}

/**
 * 当前视图要显示哪几天（'YYYY-MM-DD'），**中间那列 = 当前查看日**。
 *
 * count=1 → [current]；count=3 → [前一天, 当前, 后一天]。
 * 偶数 count 时中间偏左（这里只有 1 和 3，但别让它算崩）。
 */
export function dayDates(currentDate: string, count: number): string[] {
  const out: string[] = [];
  if (count <= 0) {
    return out;
  }
  const center: number = Math.floor((count - 1) / 2);
  const base: Date = parseDate(currentDate);
  for (let i = 0; i < count; i++) {
    out.push(formatDate(addDays(base, i - center)));
  }
  return out;
}

/** 中间列在下标里的位置（决定"哪一列可编辑"） */
export function centerIndex(count: number): number {
  if (count <= 0) {
    return 0;
  }
  return Math.floor((count - 1) / 2);
}

/** 列头文字：'10/14 周三' */
export function columnHeaderText(date: string): string {
  const d: Date = parseDate(date);
  return `${d.getMonth() + 1}/${d.getDate()} 周${WEEKDAY_CN[weekdayOf(d) - 1]}`;
}

/** 跨天拖拽的落点列：命中不到任何列（落在时间轴上 / 网格外）时返回 fallback */
export function dropColumnOrFallback(viewportW: number, count: number, x: number,
  fallback: number): number {
  const i: number = columnAtX(viewportW, count, x);
  return i < 0 ? fallback : i;
}

// ---------------- 交互判据（选中 / 长按 / 单击） ----------------

/** 单击块的结果：打开编辑窗 */
export const TAP_OPEN: string = 'open';
/** 单击块的结果：选中/改选 */
export const TAP_SELECT: string = 'select';

/**
 * 单击一个块该做什么。
 *
 * 用户 2026-10-14 定的模型：
 *   已选中的**同一条**再单击 → 开编辑窗；否则 → 选中（含"点另一条=改选"）。
 * 「未选中时双击打开」不需要额外的手势 —— 第一下选中、第二下（已在选中态）开窗，
 * 天然就满足，而且单击选中没有延迟。
 */
export function tapAction(selectedBlockId: number, blockId: number): string {
  return selectedBlockId === blockId ? TAP_OPEN : TAP_SELECT;
}

/**
 * 长按是否放行拖拽（用户要求的**两步**模型：先单击选中，再长按才拖）。
 *
 * 未选中的块长按**不响应** —— 这样"想上下滚动时间轴"的人永远不会因为按久了而误拖色块。
 * 这也是底边「⋯」把手删掉之后唯一进入拖拽的入口。
 */
export function canBeginDrag(selectedBlockId: number, blockId: number): boolean {
  return blockId !== 0 && selectedBlockId === blockId;
}
