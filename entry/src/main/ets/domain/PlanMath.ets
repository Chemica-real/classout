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
 * 拖动块时的位移：把"手指移动"换算成"块相对网格的位移"。
 *
 * 块是网格里的绝对定位元素，所以让块**钉在手指下**的条件是：
 *   手指的窗口位置 - 网格滚动量 == 常数
 * 于是：
 *   块位移 = 手指窗口位移 - 网格滚动量
 *
 * ⚠️ 这个减法是**唯一**该做补偿的地方。
 * 曾经的 bug：自动滚动定时器里又减了一次滚动量 → 块每滚一步就多走一个 EDGE_STEP，
 * 表现为"块比屏幕走得快"（用户实测：靠近上沿时块和屏幕都向下，块速度略大于屏幕）。
 *
 * @param touchDeltaY  手指的窗口坐标位移（相对按下点）
 * @param scrollDeltaY 网格滚动量（当前 - 按下时）
 */
export function dragOffsetWithScroll(touchDeltaY: number, scrollDeltaY: number): number {
  return touchDeltaY - scrollDeltaY;
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
