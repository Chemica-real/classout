import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Course, CourseSession, Semester, SessionOverride, SessionRule, SectionTime, Todo,
  TodoSource, TodoStatus, TodoTemplate, VirtualLesson } from '../model/Types';
import { TimetableRepo, } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { Db } from '../data/Db';
import { computeWeekSessions, sessionsOnDate, weekOfDate } from './Timetable';
import { addDays, formatDate, parseDate, today, weekdayOf } from '../util/DateUtil';
import { computeDdl, nextSessionOfCourse, renderTitle } from './TodoGenRules';

// 旧的调用方（页面/管理器）曾经直接从 TodoGenerator 里 import 这几个纯函数；
// 现在规则搬到 TodoGenRules 了，这里保留一层 re-export 免得外部调用点全要改。
export { computeDdl, nextSessionOfCourse, renderTitle };

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

const KV_LAST_GEN: string = 'last_gen_date';

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
      // 用户要求：「自动生成的时候不可以自动生成备注，备注直接默认为空」。
      // 模板里那个 `note` 字段不再带进待办 —— 备注是用户自己写的东西，不该被生成器代填。
      note: '',
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
    fromOverride: false,
    isExtra: false
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
