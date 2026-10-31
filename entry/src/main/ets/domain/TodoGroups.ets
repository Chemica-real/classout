import { Todo } from '../model/Types';

/**
 * 待办页的分组（用户 2026-10-30 拍定）。
 *
 * 原来的待办页是一条大列表：今天的、逾期的、几天后的混在一起，只看得到
 * 「10/28 23:59 · 逾期 3 天」这种小字，一眼分不清哪些是今天必须交的。
 * 现在竖着分成：
 *   今天   —— 截止**就是今天**、而且还没到点（到了点的算逾期）
 *   已逾期 —— 截止时刻已经过了
 *   以后   —— 明天及以后 + 没填截止
 *   已完成 —— 由 `sortDoneTodos` 单独按完成时间倒序
 *
 * ⚠️ 时间只比较**字符串**：ddl 的格式固定是 `'YYYY-MM-DD HH:mm'`，
 * 同格式下字典序就是时间序，不需要转 Date、也不受时区影响。
 * `nowStamp` 也必须是同一格式（调用方用 `formatDate(today()) + ' ' + minToHHmm(...)` 生成）。
 */

export const GROUP_TODAY: string = 'today';
export const GROUP_OVERDUE: string = 'overdue';
export const GROUP_LATER: string = 'later';

export interface TodoGroups {
  today: Todo[];
  overdue: Todo[];
  later: Todo[];
}

/** 结束得最晚的哨兵：没填截止的排在「以后」的末尾 */
const DDL_MAX: string = '9999-12-31 23:59';

/** 排序键：没截止 = 无穷远 */
function ddlKey(t: Todo): string {
  return t.ddl.length >= 16 ? t.ddl : DDL_MAX;
}

/** 同一截止时刻时按名称字母序；再相同就按 id（保证顺序稳定） */
function compareTodos(a: Todo, b: Todo): number {
  const ka: string = ddlKey(a);
  const kb: string = ddlKey(b);
  if (ka !== kb) {
    return ka < kb ? -1 : 1;
  }
  if (a.title !== b.title) {
    return a.title < b.title ? -1 : 1;
  }
  return a.id - b.id;
}

/** 截止时刻是否已经过去（没填截止永远不算逾期） */
export function isOverdue(t: Todo, nowStamp: string): boolean {
  return t.ddl.length >= 16 && t.ddl < nowStamp;
}

/**
 * 把一个待办分到哪一组。
 * @param todayStr `'YYYY-MM-DD'`（今天）
 */
export function groupOf(t: Todo, nowStamp: string, todayStr: string): string {
  if (t.ddl.length < 16) {
    return GROUP_LATER;
  }
  if (t.ddl < nowStamp) {
    return GROUP_OVERDUE;
  }
  if (t.ddl.substring(0, 10) === todayStr) {
    return GROUP_TODAY;
  }
  return t.ddl.substring(0, 10) > todayStr ? GROUP_LATER : GROUP_OVERDUE;
}

/**
 * 分组 + 排序（返回新数组，不改入参）。
 *
 * 「今天 / 已逾期 / 以后」都按截止时间升序，截止相同按名称字母序。
 */
export function groupActiveTodos(list: Todo[], nowStamp: string, todayStr: string): TodoGroups {
  const today: Todo[] = [];
  const overdue: Todo[] = [];
  const later: Todo[] = [];
  for (const t of list) {
    const g: string = groupOf(t, nowStamp, todayStr);
    if (g === GROUP_TODAY) {
      today.push(t);
    } else if (g === GROUP_OVERDUE) {
      overdue.push(t);
    } else {
      later.push(t);
    }
  }
  today.sort(compareTodos);
  overdue.sort(compareTodos);
  later.sort(compareTodos);
  return { today: today, overdue: overdue, later: later };
}

/** 已完成的顺序：完成时间倒序（最近完成的在最上面），同一时刻按 id 倒序 */
export function sortDoneTodos(list: Todo[]): Todo[] {
  const copy: Todo[] = list.slice();
  copy.sort((a: Todo, b: Todo): number => {
    if (a.doneAt !== b.doneAt) {
      return b.doneAt - a.doneAt;
    }
    return b.id - a.id;
  });
  return copy;
}

/**
 * 「还有几小时几分钟」。
 *
 * 只给**今天且未逾期**的待办用；超过 24 小时的（其实不会出现）按小时算。
 * 不足 1 分钟时给「不到 1 分钟」，别显示「还有 0 分钟」。
 */
export function remainText(dueMs: number, nowMs: number): string {
  const mins: number = Math.floor((dueMs - nowMs) / 60000);
  if (mins < 0) {
    return '';
  }
  if (mins < 1) {
    return '还有不到 1 分钟';
  }
  const h: number = Math.floor(mins / 60);
  const m: number = mins % 60;
  if (h === 0) {
    return `还有 ${m} 分钟`;
  }
  if (m === 0) {
    return `还有 ${h} 小时`;
  }
  return `还有 ${h} 小时 ${m} 分钟`;
}
