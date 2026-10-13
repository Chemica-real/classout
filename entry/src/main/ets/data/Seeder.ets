import { common } from '@kit.AbilityKit';
import { Course, DEFAULT_REST_WINDOWS, PKU_SECTION_TIMES, Semester, SessionRule,
  TodoTemplate } from '../model/Types';
import { TimetableRepo } from './TimetableRepo';
import { TodoRepo } from './TodoRepo';
import { maskAll } from '../model/WeekMask';
import { SeedCourse, SeedRule, SEED_COURSES, SEED_SEMESTER_NAME, SEED_START_DATE,
  SEED_TOTAL_WEEKS } from './SeedData';

/** 首次启动的初始化：学期 + 北大作息 + （可选）截图转录的课表 */
export class Seeder {

  /** 保证有学期和节次时间；没有就建 + 填北大 12 节 */
  static async ensureSemester(context: common.Context): Promise<Semester> {
    const existing: Semester | undefined = await TimetableRepo.getSemester(context);
    if (existing !== undefined) {
      const times = await TimetableRepo.listSectionTimes(context, existing.id);
      if (times.length === 0) {
        for (const st of PKU_SECTION_TIMES) {
          await TimetableRepo.upsertSectionTime(context, existing.id, st);
        }
      }
      return existing;
    }
    const id: number = await TimetableRepo.createSemester(context, SEED_SEMESTER_NAME,
      SEED_START_DATE, SEED_TOTAL_WEEKS);
    for (const st of PKU_SECTION_TIMES) {
      await TimetableRepo.upsertSectionTime(context, id, st);
    }
    return {
      id: id,
      name: SEED_SEMESTER_NAME,
      startDate: SEED_START_DATE,
      totalWeeks: SEED_TOTAL_WEEKS,
      firstDayOfWeek: 1,
      showWeekend: true
    };
  }

  static async hasCourses(context: common.Context, semesterId: number): Promise<boolean> {
    const courses = await TimetableRepo.listCourses(context, semesterId);
    return courses.length > 0;
  }

  /**
   * 一次性数据迁移（幂等，每次启动都跑）。
   *
   * 目前只有一项：把旧的待办时长静默搬到合法值（对齐到最近的 5 分钟、夹进 [15,600]，
   * 考试类的 0 豁免）。写成幂等 + 每次启动都跑，是为了让「从备份恢复进来的旧数据」
   * 也立刻被纠正，而不是留着不合法值在库里。
   *
   * 返回被改动的条数。
   */
  static async migrateData(context: common.Context): Promise<number> {
    return await TodoRepo.normalizeAllEstimates(context);
  }

  /** 首次启动写入默认不可排时段（午休/晚饭/睡觉），用户可改 */
  static async ensureRestWindows(context: common.Context): Promise<void> {
    const n: number = await TimetableRepo.countRestWindows(context);
    if (n > 0) {
      return;
    }
    for (const w of DEFAULT_REST_WINDOWS) {
      await TimetableRepo.insertRestWindow(context, w);
    }
  }

  /** 把截图转录的课表写进去（含生成模板） */
  static async seedCourses(context: common.Context, semesterId: number): Promise<number> {
    const mask: string = maskAll(SEED_TOTAL_WEEKS);
    let count = 0;
    for (const sc of SEED_COURSES) {
      const course: Course = {
        id: 0,
        semesterId: semesterId,
        name: sc.name,
        shortName: sc.shortName,
        teacher: sc.teacher,
        location: sc.location,
        colorIndex: sc.colorIndex,
        autoTodoEnabled: sc.templates.length > 0,
        isVirtual: false,
        note: ''
      };
      const courseId: number = await TimetableRepo.insertCourse(context, course);
      for (const r of sc.rules) {
        const rule: SessionRule = {
          id: 0,
          courseId: courseId,
          weekday: r.weekday,
          startSection: r.startSection,
          endSection: r.endSection,
          weeksMask: mask,
          location: sc.location,
          isQuiz: r.isQuiz
        };
        await TimetableRepo.insertRule(context, rule);
      }
      let order = 0;
      for (const t of sc.templates) {
        await TodoRepo.insertTemplate(context, {
          id: 0,
          courseId: courseId,
          sortOrder: order,
          enabled: true,
          titleTemplate: t.title,
          ddlRule: t.ddlRule,
          ddlParam: t.ddlParam,
          estimateMin: t.estimateMin,
          category: 'homework',
          submitChannel: '',
          note: ''
        });
        order++;
      }
      count++;
    }
    return count;
  }

  /** 清空课表（保留学期与作息） */
  static async clearCourses(context: common.Context, semesterId: number): Promise<void> {
    const courses = await TimetableRepo.listCourses(context, semesterId);
    for (const c of courses) {
      await TimetableRepo.deleteCourse(context, c.id);
    }
  }

  /**
   * 复制上学期：把 fromSemesterId 的课程、时段规则、生成模板克隆到 toSemesterId。
   * 目标学期里同名的课程会跳过（避免重复点两次变成两份）。
   * 返回新增的课程数。
   */
  static async cloneCourses(context: common.Context, fromSemesterId: number,
    toSemesterId: number): Promise<number> {
    if (fromSemesterId === toSemesterId) {
      return 0;
    }
    const source: Course[] = await TimetableRepo.listCourses(context, fromSemesterId);
    const target: Course[] = await TimetableRepo.listCourses(context, toSemesterId);
    const existingNames: Set<string> = new Set<string>();
    for (const t of target) {
      existingNames.add(t.name);
    }
    let added: number = 0;
    for (const c of source) {
      if (existingNames.has(c.name)) {
        continue;
      }
      const copy: Course = {
        id: 0,
        semesterId: toSemesterId,
        name: c.name,
        shortName: c.shortName,
        teacher: c.teacher,
        location: c.location,
        colorIndex: c.colorIndex,
        autoTodoEnabled: c.autoTodoEnabled,
        isVirtual: c.isVirtual,
        note: c.note
      };
      const newId: number = await TimetableRepo.insertCourse(context, copy);
      const rules: SessionRule[] = await TimetableRepo.listRulesOfCourse(context, c.id);
      for (const r of rules) {
        await TimetableRepo.insertRule(context, {
          id: 0,
          courseId: newId,
          weekday: r.weekday,
          startSection: r.startSection,
          endSection: r.endSection,
          weeksMask: r.weeksMask,
          location: r.location,
          isQuiz: r.isQuiz
        });
      }
      const templates: TodoTemplate[] = await TodoRepo.listTemplatesByCourse(context, c.id);
      let order: number = 0;
      for (const t of templates) {
        await TodoRepo.insertTemplate(context, {
          id: 0,
          courseId: newId,
          sortOrder: order,
          enabled: t.enabled,
          titleTemplate: t.titleTemplate,
          ddlRule: t.ddlRule,
          ddlParam: t.ddlParam,
          estimateMin: t.estimateMin,
          category: t.category,
          submitChannel: t.submitChannel,
          note: t.note
        });
        order++;
      }
      added++;
    }
    return added;
  }
}
