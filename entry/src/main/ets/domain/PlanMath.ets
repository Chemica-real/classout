/**
 * 计划视图的纯算术
 *
 * 拖拽、吸附、夹紧、找空档这些「算一下」的部分单独放这里，
 * 好处是它们不碰鸿蒙 API，可以用 tools/domain-check 离线断言（拖拽没法在真机上先试）。
 *
 * 约定：1 分钟 = 1 vp，所以 y 坐标和分钟数只差一个时间窗起点的偏移。
 */

import { PlanBlock, Todo, TodoStatus } from '../model/Types';

function clamp(v: number, lo: number, hi: number): number {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

export const SNAP_MIN: number = 15;
export const VP_PER_MIN: number = 1;
/** 一个块最短 15 分钟 */
export const MIN_BLOCK_MIN: number = SNAP_MIN;
/** 时间轴一格的跨度（分钟）。每个刻度代表它**后面**这 60 分钟。 */
export const HOUR_MIN: number = 60;

/** 吸附到 15 分钟刻度 */
export function snap(v: number): number {
  return Math.round(v / SNAP_MIN) * SNAP_MIN;
}

// ---------------- 时间窗与时间轴 ----------------

/** 时间窗：计划网格画哪一段。 */
export interface TimeWindow {
  startMin: number;
  endMin: number;
}

/** 默认时间窗 07:00–24:00（可在「管理课程」里改，见 PLAN_REDESIGN.md §2） */
export const DEFAULT_WINDOW: TimeWindow = { startMin: 7 * 60, endMin: 24 * 60 };
export const WINDOW_MIN_START: number = 0;
export const WINDOW_MAX_END: number = 24 * 60;
export const WINDOW_MIN_SPAN: number = 60;

/** 合法的时间窗：吸附到 15 分钟，并夹进可用范围 */
export function normalizeWindow(w: TimeWindow): TimeWindow {
  let s: number = clamp(snap(w.startMin), WINDOW_MIN_START, WINDOW_MAX_END - WINDOW_MIN_SPAN);
  let e: number = clamp(snap(w.endMin), WINDOW_MIN_START + WINDOW_MIN_SPAN, WINDOW_MAX_END);
  if (e - s < WINDOW_MIN_SPAN) {
    s = e - WINDOW_MIN_SPAN;
    if (s < WINDOW_MIN_START) {
      s = WINDOW_MIN_START;
      e = s + WINDOW_MIN_SPAN;
    }
  }
  return { startMin: s, endMin: e };
}

/**
 * 把时间窗对齐到整小时：start 向下取整点、end 向上取整点，再规范化。
 *
 * 为什么必须对齐：刻度是**按 60 分钟定距递增**的（07:30 → 08:30 → …），
 * 如果窗口起点不在整点或长度不是整小时，末段就会不足 60 分钟而刻度数算少，
 * 「刻度数 × 60 == 网格高度」这条不变式就崩了（实测 07:30–24:00 会差 30vp）。
 * 对齐后刻度天然铺满，且标签永远是整点 —— 时间窗本来就该按整点设。
 */
export function alignWindow(w: TimeWindow): TimeWindow {
  const n: TimeWindow = normalizeWindow(w);
  const s: number = Math.floor(n.startMin / HOUR_MIN) * HOUR_MIN;
  const e: number = Math.ceil(n.endMin / HOUR_MIN) * HOUR_MIN;
  return normalizeWindow({ startMin: s, endMin: e });
}

/**
 * 时间轴：把「画哪一段、多高、刻度在哪」收成一个不可变对象。
 *
 * ⚠️ 这里曾经是个真 bug：旧实现把时间窗做成模块级的 `DAY_START_MIN` / `GRID_H`，
 * 而刻度生成用的是**闭区间** `h <= end/60` → 06:00–24:00 生成 **19** 个刻度，
 * 但每个刻度渲染成 60vp 的一行 → 19×60 = 1140vp 塞进 1080vp 的容器，**底部那行被裁掉**。
 *
 * 现在的不变式（test.ts 有断言）：
 *   `marks.length * HOUR_MIN === height()`
 * 网格高度恰好等于所有刻度行高之和，永远不多画也不少画。
 * 靠的是**把时间窗对齐到整小时**（alignWindow），刻度才能天然铺满。
 */
export class TimeAxis {
  readonly startMin: number;
  readonly endMin: number;
  /** 刻度起点（分钟，升序），相邻相差 HOUR_MIN；一定是整点（因为时间窗对齐过） */
  readonly marks: number[];

  constructor(w: TimeWindow) {
    const n: TimeWindow = alignWindow(w);
    this.startMin = n.startMin;
    this.endMin = n.endMin;
    const m: number[] = [];
    for (let t = n.startMin; t < n.endMin; t += HOUR_MIN) {
      m.push(t);
    }
    this.marks = m;
  }

  /** 网格总高度（vp）。1 分钟 = 1vp。 */
  height(): number {
    return (this.endMin - this.startMin) * VP_PER_MIN;
  }

  /** y（vp）→ 吸附并夹紧后的分钟 */
  yToMinute(y: number): number {
    return clamp(snap(this.startMin + y / VP_PER_MIN), this.startMin, this.endMin);
  }

  /** 分钟 → y（vp） */
  minuteToY(min: number): number {
    return (min - this.startMin) * VP_PER_MIN;
  }

  /** 该分钟是否落在时间窗内 */
  contains(min: number): boolean {
    return min >= this.startMin && min <= this.endMin;
  }
}

/** 默认时间轴（模块级单例） */
export const DEFAULT_AXIS: TimeAxis = new TimeAxis(DEFAULT_WINDOW);

/** 默认窗下的网格高度（vp） */
export const GRID_H: number = DEFAULT_AXIS.height();

/**
 * 内容驱动的时间窗：让当天所有内容（课程 + 已排的块）都装得下。
 *
 * 把范围收进 [min, max] 再向两端各留 padMin，最后夹进 [floorStart, ceilEnd]。
 * 内容为空时返回 [floorStart, ceilEnd]。
 *
 * ⚠️ 两端各自夹在 [floorStart, ceilEnd] 上，**不要**拿 floorStart 去夹 end ——
 * 那样 end 会被压到下限，窗口塌成 1 小时（曾写出这个 bug，被 test.ts 抓到）。
 */
export function windowForContent(contentMins: number[], padMin: number,
  floorStart: number, ceilEnd: number): TimeWindow {
  if (contentMins.length === 0) {
    return alignWindow({ startMin: floorStart, endMin: ceilEnd });
  }
  let lo: number = contentMins[0];
  let hi: number = contentMins[0];
  for (const m of contentMins) {
    if (m < lo) {
      lo = m;
    }
    if (m > hi) {
      hi = m;
    }
  }
  const s: number = clamp(snap(lo - padMin), floorStart, ceilEnd);
  let e: number = clamp(snap(hi + padMin), floorStart, ceilEnd);
  // 夹紧后可能塌成过窄的窗（内容整体在 floor 之外时），至少撑到最小跨度
  if (e - s < WINDOW_MIN_SPAN) {
    const want: number = clamp(snap(hi + padMin), s + WINDOW_MIN_SPAN, ceilEnd);
    e = want > s ? want : Math.min(ceilEnd, s + WINDOW_MIN_SPAN);
  }
  if (e - s < WINDOW_MIN_SPAN) {
    return alignWindow({ startMin: Math.max(floorStart, e - WINDOW_MIN_SPAN), endMin: e });
  }
  return alignWindow({ startMin: s, endMin: e });
}

// ---------------- 时长与位置 ----------------

/** 时长（分钟）→ 高度（vp） */
export function durationToH(min: number): number {
  return min * VP_PER_MIN;
}

/**
 * 规范化时长：至少 15 分钟。
 *
 * ⚠️ **不再吸附到 15 的整数倍**。原来这里会 `snap(min)`，于是自定义填「20 分钟」
 * 会被悄悄改成 15 分钟。现在时长是用户的输入，保持精确。
 * 起点照旧吸附（见 dropRange），所以落入网格的位置仍然对齐，
 * 只是「起点 + 精确时长」= 结束时间，可能停在非整刻（如 19:05 + 20 = 19:25）。
 */
export function normalizeDuration(min: number): number {
  if (min <= 0) {
    return 60;
  }
  return Math.max(MIN_BLOCK_MIN, min);
}

/**
 * 把「时长 durationMin 的块」放到 y 处，返回 [start, end]。
 *
 * 起点按全局刻度吸附；**时长原样保留**，结束时间由 `起点 + 时长` 得出。
 * 这样非 15 整数倍的时长不会被改掉（以开始时间为参考，见 normalizeDuration 的说明）。
 */
export function dropRange(axis: TimeAxis, y: number, durationMin: number): number[] {
  const dur: number = normalizeDuration(durationMin);
  let start: number = axis.yToMinute(y);
  if (start + dur > axis.endMin) {
    start = axis.endMin - dur;
  }
  if (start < axis.startMin) {
    start = axis.startMin;
  }
  return [start, start + dur];
}

/** 竖直拖动移动块：时长不变，整体平移并夹在窗口范围内 */
export function moveRange(axis: TimeAxis, startMin: number, endMin: number,
  deltaY: number): number[] {
  const dur: number = endMin - startMin;
  const start: number = clamp(snap(startMin + deltaY / VP_PER_MIN),
    axis.startMin, axis.endMin - dur);
  return [start, start + dur];
}

/** 拖底边改时长：起点不动，最短 15 分钟，最晚到窗口末尾 */
export function resizeRange(axis: TimeAxis, startMin: number, endMin: number,
  deltaY: number): number[] {
  const end: number = clamp(snap(endMin + deltaY / VP_PER_MIN),
    startMin + MIN_BLOCK_MIN, axis.endMin);
  return [startMin, end];
}

/** 两个区间是否重叠（半开区间） */
export function overlaps(aStart: number, aEnd: number, bStart: number, bEnd: number): boolean {
  return aStart < bEnd && bStart < aEnd;
}

/**
 * 某个待办的全部时间块是否都已完成。
 *
 * ⚠️ 必须传「跨全部日期」的块，不能只传当天的：
 * 一个待办本来就可以拆成多块、分散在不同天（今天做 1 小时、明天再做 1 小时），
 * 只看当天会把「今天这块做完」误判成「整个待办做完」。
 * 没有任何块时返回 false（没有依据说它完成了）。
 */
export function allBlocksDone(blocks: PlanBlock[], todoId: number): boolean {
  let any: boolean = false;
  for (const b of blocks) {
    if (b.todoId === todoId) {
      any = true;
      if (!b.done) {
        return false;
      }
    }
  }
  return any;
}

/**
 * 一键找空档：在 busy（课表 + 已排的计划块）与 rest（不可排时段：午休/晚饭/睡觉）之外，
 * 找 fromMin 之后最早能放下 durationMin 的位置。找不到返回 -1。
 */
export function findFreeSlot(axis: TimeAxis, busy: number[][], rest: number[][],
  durationMin: number, fromMin: number): number {
  const dur: number = normalizeDuration(durationMin);
  const blocked: number[][] = busy.concat(rest);
  const earliest: number = clamp(snap(fromMin), axis.startMin, axis.endMin);
  const totalSlots: number = Math.floor((axis.endMin - axis.startMin) / SNAP_MIN);
  for (let i = 0; i <= totalSlots; i++) {
    const start: number = axis.startMin + i * SNAP_MIN;
    if (start < earliest) {
      continue;
    }
    if (start + dur > axis.endMin) {
      break;
    }
    let ok: boolean = true;
    for (const b of blocked) {
      if (overlaps(start, start + dur, b[0], b[1])) {
        ok = false;
        break;
      }
    }
    if (ok) {
      return start;
    }
  }
  return -1;
}

/**
 * 拖动块时是否该自动滚时间轴，以及往哪个方向滚。
 *
 * 规则：触摸点进入距可视区上/下边缘 edgeZone 之内就滚，
 * 往上沿滚（内容跟着上移，露出更早的时间）。两侧同时满足时取更近的那边。
 *
 * @param touchWinY      触摸点的窗口 y
 * @param viewTop        网格可视区上边界（窗口 y）
 * @param viewBottom     网格可视区下边界（窗口 y）
 * @param edgeZone       触发区高度（vp）
 * @returns 负数=向上滚，正数=向下滚，0=不滚
 */
export function edgeScrollDirection(touchWinY: number, viewTop: number, viewBottom: number,
  edgeZone: number): number {
  const span: number = viewBottom - viewTop;
  if (span <= 0) {
    return 0;
  }
  const fromTop: number = touchWinY - viewTop;
  const fromBottom: number = viewBottom - touchWinY;
  const atTop: boolean = fromTop < edgeZone;
  const atBottom: boolean = fromBottom < edgeZone;
  if (atTop && atBottom) {
    // 视口比两个触发区还矮：取更近的一边，避免两边打架
    return fromTop <= fromBottom ? -1 : 1;
  }
  if (atTop) {
    return -1;
  }
  if (atBottom) {
    return 1;
  }
  return 0;
}

/**
 * 触摸点进入边缘触发区的**深度**：0 = 刚跨进触发区边界，edgeZone = 已经贴到（或越过）屏幕边。
 *
 * 为什么需要它：旧的自动滚动是「每 50ms 硬跳 16vp」，不论贴得多深速度都一样，
 * 用户看到的是一格一格的台阶（实测报「拖到最上最下时不跟手、时间轴跳动不顺滑」）。
 * 有了深度就能让速度随深度线性增长 —— 刚进区几乎不动、贴边最快。
 */
export function edgeScrollDepth(touchWinY: number, viewTop: number, viewBottom: number,
  edgeZone: number): number {
  const dir: number = edgeScrollDirection(touchWinY, viewTop, viewBottom, edgeZone);
  if (dir === 0 || edgeZone <= 0) {
    return 0;
  }
  const fromEdge: number = dir < 0 ? touchWinY - viewTop : viewBottom - touchWinY;
  return clamp(edgeZone - fromEdge, 0, edgeZone);
}

/**
 * 自动滚动**每帧**该走多少 vp：按进入深度线性加速，并至少 1vp
 *（否则刚跨过触发边界时会「定时器已经在跑但画面不动」，看着像卡住）。
 */
export function edgeScrollStep(depth: number, edgeZone: number, maxStep: number): number {
  if (edgeZone <= 0 || maxStep <= 0) {
    return 0;
  }
  const frac: number = clamp(depth / edgeZone, 0, 1);
  const s: number = maxStep * frac;
  if (s < 1) {
    return 1;
  }
  if (s > maxStep) {
    return maxStep;
  }
  return Math.round(s);
}

/**
 * 按「日期 → 开始时间」排序块的副本。
 * 编辑窗里「这个待办还在别的哪天排了块」必须按时间读，否则用户看到的顺序是随机的。
 */
export function sortBlocksByTime(blocks: PlanBlock[]): PlanBlock[] {
  const out: PlanBlock[] = blocks.slice();
  out.sort((a: PlanBlock, b: PlanBlock): number => {
    if (a.date < b.date) {
      return -1;
    }
    if (a.date > b.date) {
      return 1;
    }
    if (a.startMin !== b.startMin) {
      return a.startMin - b.startMin;
    }
    return a.id - b.id;
  });
  return out;
}

/**
 * 拖动块时的位移：把"手指移动"换算成"块相对网格内容的位移"。
 *
 * 推导（块是网格内容里的绝对定位元素）：
 *   块在窗口里的位置 = 内容在窗口里的顶边 + 块在内容里的 y
 *                    = (视口顶边 − 滚动量) + (原 y + dragOffsetY)
 *   要让它**钉在手指下**（窗口位置 = 按下点 + 手指位移），就得：
 *       dragOffsetY = 手指位移 **+** 滚动量
 *
 * 物理直觉：手指停在屏幕下边缘不动、屏幕继续往下滚（露出更晚的时间），
 * 网格内容整体上移；块若不跟着往下推，就会留在原地、从手指底下溜走。
 *
 * ⚠️⚠️ 这里原先写的是 `touchDeltaY - scrollDeltaY`，**符号是反的**。
 * 症状正是用户报的「拖到屏幕上下边缘时待办不再跟手跑」——
 * 自动滚动时块朝着与滚动相反的方向多跑一倍，直接逃离手指。
 *
 * 旧断言没抓到它，是因为那些断言把同一套错误模型又写了一遍
 * （"块在窗口中的位置 = 位移 ＋ 滚动量"）——
 * **把实现重述一遍的断言，发现不了建模错误。** 这是本轮最值得记的教训。
 *
 * @param touchDeltaY  手指的窗口坐标位移（相对按下点）
 * @param scrollDeltaY 网格滚动量（当前 − 按下时）；向下滚为正
 */
export function dragOffsetWithScroll(touchDeltaY: number, scrollDeltaY: number): number {
  return touchDeltaY + scrollDeltaY;
}

/**
 * 「待安排」托盘里该显示哪些待办。
 *
 * 规则：状态为 active、且**给定日期**还没有排过块。
 *
 * ⚠️ `blocks` 必须是**该日期当天**的块（调用方传 listBlocksOn 的结果）。
 * 只用当天过滤是刻意的：待办允许拆成多块分散在不同天，换到另一天时它应当重新出现在托盘里。
 *
 * 漏掉"当天已排"这一步会出现「拖进网格后托盘里还在、可以反复拖出重复块」的 bug（用户实测报过）。
 * 判据与虚拟课时托盘保持一致（那边是 poolLessons，按 lessonId 过滤）。
 */
/**
 * 这一天该待办**已经排过了**吗。
 *
 * 为什么要有它（用户实测）：从「待安排」把待办拖到**侧列那一天**之后，它按设计
 * **仍然留在托盘里**（托盘的过滤只看"当前查看日"，这样"拆成多块分散在不同天"才可行）。
 * 但用户会以为"没排上"，于是又拖一次 —— 同一天就多出一块；
 * 而 `syncTodoDuration` 会把该待办**所有**块的时长加起来写回 `estimate_min`，
 * 于是"预计时间越来越长"（用户报的第二个症状）。
 *
 * 所以：**同一天不允许出现第二块**（要加长请点开那块改时长；要分散请排到别的天）。
 * 注意它只挡"同一天"，跨天拆块仍然允许。
 */
export function hasBlockOnDate(blocks: PlanBlock[], todoId: number, date: string): boolean {
  for (const b of blocks) {
    if (b.todoId === todoId && b.date === date) {
      return true;
    }
  }
  return false;
}

/**
 * 该待办**已经排在哪几天**（升序、去重）。
 * 用于「待安排」卡片上的"已排 10/15"角标 —— 这样即使它按设计还留在托盘里，
 * 用户也能一眼看出"刚才那一下生效了"，不会重复拖。
 */
export function scheduledDays(blocks: PlanBlock[], todoId: number): string[] {
  const set: Set<string> = new Set<string>();
  for (const b of blocks) {
    if (b.todoId === todoId) {
      set.add(b.date);
    }
  }
  const out: string[] = [];
  set.forEach((d: string): void => {
    out.push(d);
  });
  out.sort();
  return out;
}

export function selectPoolTodos(todos: Todo[], blocks: PlanBlock[]): Todo[] {
  const scheduled: Set<number> = new Set<number>();
  for (const b of blocks) {
    if (b.todoId > 0) {
      scheduled.add(b.todoId);
    }
  }
  const out: Todo[] = [];
  for (const t of todos) {
    if (t.status === TodoStatus.Active && !scheduled.has(t.id)) {
      out.push(t);
    }
  }
  return out;
}

/**
 * 「待安排」托盘的排序：有截止时间的在前（按截止升序），无截止的排最后。
 * 同一截止时间时按 id 升序，保证顺序稳定（ForEach 的 key 依赖它）。
 */
export function sortPoolTodos(todos: Todo[]): Todo[] {
  const out: Todo[] = todos.slice();
  out.sort((a: Todo, b: Todo): number => {
    const ad: string = a.ddl;
    const bd: string = b.ddl;
    const aHas: boolean = ad.length > 0;
    const bHas: boolean = bd.length > 0;
    if (aHas && bHas) {
      if (ad < bd) {
        return -1;
      }
      if (ad > bd) {
        return 1;
      }
      return a.id - b.id;
    }
    if (aHas) {
      return -1;
    }
    if (bHas) {
      return 1;
    }
    return a.id - b.id;
  });
  return out;
}
