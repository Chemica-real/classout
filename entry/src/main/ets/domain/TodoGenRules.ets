/**
 * 下课自动生成待办的**纯规则**（不碰数据库/上下文，能离线断言、也能冻成 fixtures）。
 *
 * 为什么单独一个文件：`TodoGenerator.ets` 里那些"读模板、查重、写库"的部分离不开
 * `common.Context`，没法进 `tools/domain-check`；而"标题怎么渲染、截止怎么算、下一节课在哪天"
 * 是纯的 —— 抽出来之后，鸿蒙端 524 条断言、Android 的 `todo_generator.dart`、
 * 以及 `shared/fixtures/todo_gen.json` 就能互相咬住。
 *
 * ⚠️ 改动这里的任何规则，都要重新跑 `./tools/sync-contract.sh` 让三端对齐。
 */

import { Course, CourseSession, Semester, SessionOverride, SessionRule, SectionTime,
  TodoTemplate } from '../model/Types';
import { sessionsOnDate } from './Timetable';
import { addDays, formatDate, monthDayText, parseDate, weekdayOf } from '../util/DateUtil';

/** next_session 向前找多少天 */
export const LOOKAHEAD_DAYS: number = 28;

/** ArkTS 下不用正则，手写替换（课程名里出现 $& 之类也不会出事） */
function replaceAll(src: string, token: string, value: string): string {
  let out: string = src;
  let idx: number = out.indexOf(token);
  while (idx >= 0) {
    out = out.substring(0, idx) + value + out.substring(idx + token.length);
    idx = out.indexOf(token, idx + value.length);
  }
  return out;
}

/**
 * 模板变量替换
 *   %C 课程全名   %c 简称     %D 布置日期(M.D)   %d 布置日期(YYYY-MM-DD)
 *   %W 第几周     %T 起始节次  %N 第 N 次作业     %R 教室
 */
export function renderTitle(tpl: string, s: CourseSession, week: number, n: number): string {
  let out: string = tpl;
  out = replaceAll(out, '%C', s.course.name);
  out = replaceAll(out, '%c', s.course.shortName.length > 0 ? s.course.shortName : s.course.name);
  out = replaceAll(out, '%D', monthDayText(parseDate(s.date)));
  out = replaceAll(out, '%d', s.date);
  out = replaceAll(out, '%W', `${week}`);
  out = replaceAll(out, '%T', `${s.startSection}`);
  out = replaceAll(out, '%N', `${n}`);
  out = replaceAll(out, '%R', s.location);
  return out;
}

/** 找某门课在 afterDate 之后（不含当天）的第一节课 */
export function nextSessionOfCourse(sem: Semester, courses: Course[], rules: SessionRule[],
  overrides: SessionOverride[], times: SectionTime[], courseId: number,
  afterDate: Date): CourseSession | undefined {
  for (let i = 1; i <= LOOKAHEAD_DAYS; i++) {
    const d: Date = addDays(afterDate, i);
    const sessions: CourseSession[] = sessionsOnDate(sem, courses, rules, overrides, times, d);
    for (const s of sessions) {
      if (s.course.id === courseId) {
        return s;
      }
    }
  }
  return undefined;
}

/**
 * 计算截止时间字符串 'YYYY-MM-DD HH:mm'
 *   none          不设截止
 *   same_day      当天 23:59
 *   days:N        N 天后 23:59
 *   weekday:N     最近（含当天）的星期 N 23:59
 *   week_end      本周日 23:59
 *   next_session  下一次同门课当天 23:59
 */
export function computeDdl(sem: Semester, courses: Course[], rules: SessionRule[],
  overrides: SessionOverride[], times: SectionTime[], s: CourseSession, ddlRule: string,
  ddlParam: string): string {
  const base: Date = parseDate(s.date);
  if (ddlRule === 'none') {
    return '';
  }
  if (ddlRule === 'same_day') {
    return `${s.date} 23:59`;
  }
  if (ddlRule === 'days') {
    const n: number = parseInt(ddlParam, 10);
    const step: number = isNaN(n) ? 1 : n;
    return `${formatDate(addDays(base, step))} 23:59`;
  }
  if (ddlRule === 'weekday') {
    const target: number = parseInt(ddlParam, 10);
    const want: number = isNaN(target) ? 7 : target;
    const delta: number = (want - weekdayOf(base) + 7) % 7;
    return `${formatDate(addDays(base, delta))} 23:59`;
  }
  if (ddlRule === 'week_end') {
    const delta: number = 7 - weekdayOf(base);
    return `${formatDate(addDays(base, delta))} 23:59`;
  }
  if (ddlRule === 'next_session') {
    const next: CourseSession | undefined =
      nextSessionOfCourse(sem, courses, rules, overrides, times, s.course.id, base);
    const d: Date = next === undefined ? addDays(base, 7) : parseDate(next.date);
    return `${formatDate(d)} 23:59`;
  }
  return '';
}

