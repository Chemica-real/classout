import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Course, CourseSession, Semester, SessionOverride, SessionRule, SectionTime, Todo,
  TodoSource, TodoStatus, TodoTemplate, VirtualLesson } from '../model/Types';
import { TimetableRepo, } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { Db } from '../data/Db';
import { computeWeekSessions, sessionsOnDate, weekOfDate } from './Timetable';
import { addDays, formatDate, parseDate, today, weekdayOf } from '../util/DateUtil';
import { computeDdl, lessonSessionFor, nextSessionOfCourse, planSessionTodos, renderTitle }
  from './TodoGenRules';

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
  const templates: TodoTemplate[] = await TodoRepo.listTemplatesByCourse(context, s.course.id);
  const allKeys: string[] = await TodoRepo.listGenerationKeys(context);
  const count: number = await TodoRepo.countTemplateTodos(context, s.course.id);
  const planned = planSessionTodos(sem, courses, rules, times, templates, s, allKeys, count);
  let created: number = 0;
  for (const p of planned) {
    if (await TodoRepo.isBlacklisted(context, p.key)) {
      continue;
    }
    const todo: Todo = {
      id: 0,
      title: p.title,
      courseId: s.course.id,
      category: p.category,
      priority: 1,
      ddl: p.ddl,
      endAt: '',
      estimateMin: p.estimateMin,
      status: TodoStatus.Pending,
      source: TodoSource.Template,
      generationKey: p.key,
      // 用户要求：「自动生成的时候不可以自动生成备注」
      note: '',
      submitChannel: p.submitChannel,
      repeatRule: '',
      photos: '',
      createdAt: Date.now(),
      confirmedAt: 0,
      doneAt: 0
    };
    await TodoRepo.insertTodo(context, todo);
    created++;
    hilog.info(DOMAIN, TAG, 'generated todo: %{public}s @ %{public}s', p.title, s.date);
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
  const s: CourseSession = lessonSessionFor(course, date, startMin, endMin, course.location);
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
