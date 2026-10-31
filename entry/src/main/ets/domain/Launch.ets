/**
 * 「启动」相关的纯逻辑（用户 2026-10-30）。
 *
 * 两件事：
 *   1. 快速启动：打开 App 时不播加载动画，直接进界面，同步在后台静默做；
 *   2. 默认进入哪个标签页：课表 / 待办 / 计划 / 设置。
 *
 * 抽出来是为了让「存坏了的值怎么办」有唯一答案，并且能进离线断言：
 * kv 里可能是空串、负数、99、`'3abc'`，任何一种都不能让 Index 切到一个不存在的标签。
 */

/** 标签页下标（与 `Index.tab` 一一对应） */
export const TAB_TIMETABLE: number = 0;
export const TAB_TODO: number = 1;
export const TAB_PLAN: number = 2;
export const TAB_SETTINGS: number = 3;
export const TAB_COUNT: number = 4;

/**
 * 规范化「默认进入」的标签：
 * 非整数 / 越界 / NaN 一律回到课表（0）。
 * ⚠️ 不要"夹紧"到 3：用户选了 99 说明数据坏了，回默认比停在一个随机页更可预期。
 */
export function normalizeDefaultTab(raw: number): number {
  if (!Number.isFinite(raw)) {
    return TAB_TIMETABLE;
  }
  const n: number = Math.floor(raw);
  if (n < 0 || n >= TAB_COUNT) {
    return TAB_TIMETABLE;
  }
  return n;
}

/** 设置页那排胶囊上的中文名 */
export function tabLabel(tab: number): string {
  const t: number = normalizeDefaultTab(tab);
  if (t === TAB_TODO) {
    return '待办';
  }
  if (t === TAB_PLAN) {
    return '计划';
  }
  if (t === TAB_SETTINGS) {
    return '设置';
  }
  return '课表';
}
