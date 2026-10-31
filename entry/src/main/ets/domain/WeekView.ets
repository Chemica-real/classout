/**
 * 周视图的纯算术：一周从周一排到周日、整周 + 整天一屏的坐标、周页码与周号。
 *
 * 为什么单独一层：周视图的"点某天某时放大到三日"、"整周铺满 7 列"、
 * "一天压到一屏"全是几何；放在 UI 里会像之前那样只能靠真机截图试，改一次量一次。
 * 这里进离线断言，UI 只负责把结果画出来。
 */

import { addDays, formatDate, parseDate, WEEKDAY_CN, weekdayOf } from '../util/DateUtil';
import { Semester } from '../model/Types';
import { weekOfDate } from './Timetable';

/** 一周 7 天（周一到周日） */
export const WEEK_DAYS: number = 7;
/** 周视图横向保留的周页数（奇数，当前周在正中） */
export const WEEK_PAGES: number = 9;
/** 当前周在周页数组里的下标 */
export const WEEK_CENTER: number = 4;
/** 周视图列头高度（比三日列头矮，给整天让高度） */
export const WEEK_HEAD_H: number = 28;
/**
 * 周视图块标题字号。用户要求「15 分钟及以上的块标题均显示」；
 * 15 分钟在整周整天一屏里约 7vp 高，6vp 单行刚好塞下。屏幕太矮时不强塞。
 */
export const WEEK_TITLE_FONT: number = 6;
/** 块高至少这么多才画标题；更矮只画色带（不溢出块边界） */
export const WEEK_TITLE_MIN_H: number = 6;

/** 某天所在教学周的周一（'YYYY-MM-DD'） */
export function weekStartOf(dateStr: string): string {
  const d: Date = parseDate(dateStr);
  return formatDate(addDays(d, 1 - weekdayOf(d)));
}

/** 某天所在周的 7 天，周一到周日 */
export function weekDatesOf(dateStr: string): string[] {
  const start: Date = parseDate(weekStartOf(dateStr));
  const out: string[] = [];
  for (let i = 0; i < WEEK_DAYS; i++) {
    out.push(formatDate(addDays(start, i)));
  }
  return out;
}

/**
 * 周视图横向的 WEEK_PAGES 周日期（共 63 天），当前周在正中。
 * 横向滑到边上时用它重切，不查库。
 */
export function weekPageDates(dateStr: string, pages: number = WEEK_PAGES,
  center: number = WEEK_CENTER): string[] {
  const start: Date = addDays(parseDate(weekStartOf(dateStr)), -center * WEEK_DAYS);
  const out: string[] = [];
  for (let i = 0; i < pages * WEEK_DAYS; i++) {
    out.push(formatDate(addDays(start, i)));
  }
  return out;
}

/** 某天在 weekPageDates 结果里的周页下标；找不到时退回 center */
export function weekPageOfDate(dateStr: string, dates: string[],
  center: number = WEEK_CENTER): number {
  const i: number = dates.indexOf(dateStr);
  if (i < 0) {
    return center;
  }
  return Math.floor(i / WEEK_DAYS);
}

/** 第 page 页的周一（dates 是 weekPageDates 的结果） */
export function weekPageStart(dates: string[], page: number): string {
  const i: number = page * WEEK_DAYS;
  return i >= 0 && i < dates.length ? dates[i] : '';
}

/** 第 page 页的周日 */
export function weekPageEnd(dates: string[], page: number): string {
  const i: number = page * WEEK_DAYS + WEEK_DAYS - 1;
  return i >= 0 && i < dates.length ? dates[i] : '';
}

/** '10/26 ~ 11/1' */
export function weekRangeText(start: string, end: string): string {
  if (start.length === 0 || end.length === 0) {
    return '';
  }
  const a: Date = parseDate(start);
  const b: Date = parseDate(end);
  return `${a.getMonth() + 1}/${a.getDate()} ~ ${b.getMonth() + 1}/${b.getDate()}`;
}

/**
 * 周号文案：学期周（和页头「第 N 周」一致），学期外写「假期」。
 * 用这一周的周一算；学期第一周从周一开始，所以不会出现半周。
 */
export function weekNumberLabel(sem: Semester | undefined, weekStartDate: string): string {
  if (sem === undefined || weekStartDate.length === 0) {
    return '';
  }
  const w: number = weekOfDate(sem, parseDate(weekStartDate));
  if (w < 1 || w > sem.totalWeeks) {
    return '假期';
  }
  return `第 ${w} 周`;
}

/** 周视图的纵向坐标：整周整天一屏时，minute 落在 gridH 里的 y */
export function weekMinuteY(minute: number, startMin: number, endMin: number,
  gridH: number): number {
  const span: number = endMin - startMin;
  if (span <= 0 || gridH <= 0) {
    return 0;
  }
  return (minute - startMin) / span * gridH;
}

/** 周视图点击 y → 分钟（夹在时间窗内） */
export function weekTapMinute(localY: number, startMin: number, endMin: number,
  gridH: number): number {
  const span: number = endMin - startMin;
  if (span <= 0 || gridH <= 0) {
    return startMin;
  }
  const m: number = startMin + localY / gridH * span;
  if (m < startMin) {
    return startMin;
  }
  if (m > endMin) {
    return endMin;
  }
  return m;
}

/** 周视图块高够不够塞一行标题 */
export function weekBlockTitleVisible(blockH: number): boolean {
  return blockH >= WEEK_TITLE_MIN_H;
}

/** 横向滚动位置 → 周页下标（四舍五入并夹住） */
export function weekPageFromOffset(x: number, pageW: number, pages: number): number {
  if (pageW <= 0) {
    return 0;
  }
  let p: number = Math.round(x / pageW);
  if (p < 0) {
    p = 0;
  }
  if (p > pages - 1) {
    p = pages - 1;
  }
  return p;
}

/** 周页下标 → 横向滚动位置 */
export function weekPageOffset(page: number, pageW: number): number {
  return page * pageW;
}

/** 周视图列头的两行：'10/26'、'周一' */
export function weekHeaderDateText(date: string): string {
  const d: Date = parseDate(date);
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

export function weekHeaderWeekdayText(date: string): string {
  return `周${WEEKDAY_CN[weekdayOf(parseDate(date)) - 1]}`;
}
