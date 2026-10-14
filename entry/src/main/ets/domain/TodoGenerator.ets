import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Course, CourseSession, Semester, SessionOverride, SessionRule, SectionTime, Todo,
  TodoSource, TodoStatus, TodoTemplate, VirtualLesson } from '../model/Types';
import { TimetableRepo, } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { Db } from '../data/Db';
import { computeWeekSessions, sessionsOnDate, weekOfDate } from './Timetable';
import { addDays, formatDate, monthDayText, parseDate, today, weekdayOf } from '../util/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

const KV_LAST_GEN: string = 'last_gen_date';
/** next_session 向前找多少天 */
const LOOKAHEAD_DAYS: number = 28;

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

export interface GenerationOutcome {
  created: number;
  scannedDays: number;
}

/**
 * 为「一节课」按课程模板生成待办。
 *
 * 真课下课、虚拟课程的课时完成，走的都是这里 —— 这是「课时结束就触发」的唯一实现。
 * 返回新建条数。去重键是 `课程|日期|模板`，所以同一节课重复触发不会生成两份。
 */
export async function generateForSession(context: common.Context, sem: Semester, courses: Course[],
  rules: SessionRule[], times: SectionTime[], overrides: SessionOverride[],
  s: CourseSession): Promise<number> {
  if (!s.course.autoTodoEnabled) {
    return 0;
  }
  let created: number = 0;
  const templates: TodoTemplate[] = await TodoRepo.listTemplatesByCourse(context, s.course.id);
  for (const t of templates) {
    if (!t.enabled) {
      continue;
    }
    const key: string = `${s.course.id}|${s.date}|${t.id}`;
    if (await TodoRepo.hasGenerationKey(context, key)) {
      continue;
    }
    if (await TodoRepo.isBlacklisted(context, key)) {
      continue;
    }
    const n: number = await TodoRepo.countTemplateTodos(context, s.course.id) + 1;
    const week: number = weekOfDate(sem, parseDate(s.date));
    const title: string = renderTitle(t.titleTemplate, s, week, n);
    const ddl: string = computeDdl(sem, courses, rules, overrides, times, s, t.ddlRule, t.ddlParam);
    const todo: Todo = {
      id: 0,
      title: title,
      courseId: s.course.id,
      category: t.category,
      priority: 1,
      ddl: ddl,
      endAt: '',
      estimateMin: t.estimateMin,
      status: TodoStatus.Pending,
      source: TodoSource.Template,
      generationKey: key,
      note: t.note,
      submitChannel: t.submitChannel,
      repeatRule: '',
      photos: '',
      createdAt: Date.now(),
      confirmedAt: 0,
      doneAt: 0
    };
    await TodoRepo.insertTodo(context, todo);
    created++;
    hilog.info(DOMAIN, TAG, 'generated todo: %{public}s @ %{public}s', title, s.date);
  }
  return created;
}

/**
 * 虚拟课程的某一讲完成 → 跟真课下课一样触发。
 * 用计划块的日期与起止时间伪造一个 CourseSession（虚拟课程本来就没有节次规则）。
 */
export async function generateForLesson(context: common.Context, sem: Semester,
  lesson: VirtualLesson, date: string, startMin: number, endMin: number): Promise<number> {
  const courses: Course[] = await TimetableRepo.listCourses(context, sem.id);
  let course: Course | undefined = undefined;
  for (const c of courses) {
    if (c.id === lesson.courseId) {
      course = c;
    }
  }
  if (course === undefined) {
    return 0;
  }
  const rules: SessionRule[] = await TimetableRepo.listRules(context, sem.id);
  const times: SectionTime[] = await TimetableRepo.listSectionTimes(context, sem.id);
  const synthetic: SessionRule = {
    id: 0,
    courseId: course.id,
    weekday: 0,
    startSection: 0,
    endSection: 0,
    weeksMask: '',
    location: course.location,
    isQuiz: false
  };
  const s: CourseSession = {
    course: course,
    rule: synthetic,
    date: date,
    originDate: date,
    weekday: weekdayOf(parseDate(date)),
    startSection: 0,
    endSection: 0,
    startMin: startMin,
    endMin: endMin,
    location: course.location,
    isQuiz: false,
    fromOverride: false
  };
  return await generateForSession(context, sem, courses, rules, times, [], s);
}

/**
 * 静默补生成。
 *
 * 鸿蒙不允许 App 后台常驻（延迟任务最小 2 小时），所以「下课那一刻生成」落地成：
 * 每次打开 App 时，把从上次检查到今天之间**已经下课**的课时补生成出来，
 * 时间戳仍记为该节课的下课时刻。生成的待办状态是 pending（待确认）。
 */
export async function generateMissedTodos(context: common.Context,
  sem: Semester): Promise<GenerationOutcome> {
  const outcome: GenerationOutcome = { created: 0, scannedDays: 0 };
  const last: string = await Db.getKv(context, KV_LAST_GEN);
  const now: Date = today();
  const endDate: Date = now;
  let startDate: Date = now;
  if (last.length > 0) {
    startDate = parseDate(last);
  }
  if (startDate.getTime() > endDate.getTime()) {
    startDate = endDate;
  }

  const courses: Course[] = await TimetableRepo.listCourses(context, sem.id);
  if (courses.length === 0) {
    await Db.setKv(context, KV_LAST_GEN, formatDate(endDate));
    return outcome;
  }
  const rules: SessionRule[] = await TimetableRepo.listRules(context, sem.id);
  const times: SectionTime[] = await TimetableRepo.listSectionTimes(context, sem.id);

  const nowDate: Date = new Date();
  const nowMin: number = nowDate.getHours() * 60 + nowDate.getMinutes();

  const totalDays: number = Math.round((endDate.getTime() - startDate.getTime()) / 86400000);
  for (let offset = 0; offset <= totalDays; offset++) {
    const d: Date = addDays(startDate, offset);
    outcome.scannedDays++;
    const isToday: boolean = d.getTime() === endDate.getTime();
    const overrides: SessionOverride[] = await TimetableRepo.listOverridesBetween(context,
      formatDate(d), formatDate(d));
    const sessions: CourseSession[] = sessionsOnDate(sem, courses, rules, overrides, times, d);
    for (const s of sessions) {
      // 还没下课就跳过
      if (isToday && s.endMin > nowMin) {
        continue;
      }
      outcome.created +=
        await generateForSession(context, sem, courses, rules, times, overrides, s);
    }
  }

  await Db.setKv(context, KV_LAST_GEN, formatDate(endDate));
  return outcome;
}
