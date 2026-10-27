import { common } from '@kit.AbilityKit';
import { Course, DEFAULT_REST_WINDOWS, DEFAULT_SECTION_TIMES, Semester, SessionRule,
  TodoTemplate } from '../model/Types';
import { TimetableRepo } from './TimetableRepo';
import { TodoRepo } from './TodoRepo';
import { formatDate, today } from '../util/DateUtil';

/**
 * 首次启动的初始化：**学期 + 作息节次**。
 *
 * ⚠️ 发布前改过：这里以前还会把作者本人的课表（截图转录的"种子课表"）灌进去 ——
 * 那既是个人数据，对新用户也毫无意义。现在**App 不内置任何课表**，
 * 新装用户拿到的是一个空的学期 + 默认 12 节作息，课表靠自己建（见 README 的"从零开始"）。
 */

/** 默认学期名与长度（新装用户看到的第一个学期，随时可在「管理课程 → 学期」改） */
const DEFAULT_SEMESTER_NAME: string = '我的学期';
const DEFAULT_TOTAL_WEEKS: number = 16;

/** 取某天所在那一周的周一（周一=1 … 周日=7） */
function mondayOf(d: Date): Date {
  const dow: number = d.getDay() === 0 ? 7 : d.getDay();
  const out: Date = new Date(d.getTime());
  out.setDate(out.getDate() - (dow - 1));
  return out;
}

export class Seeder {

  /** 保证有学期和节次时间；没有就建 + 填默认 12 节 */
  static async ensureSemester(context: common.Context): Promise<Semester> {
    const existing: Semester | undefined = await TimetableRepo.getSemester(context);
    if (existing !== undefined) {
      const times = await TimetableRepo.listSectionTimes(context, existing.id);
      if (times.length === 0) {
        for (const st of DEFAULT_SECTION_TIMES) {
          await TimetableRepo.upsertSectionTime(context, existing.id, st);
        }
      }
      return existing;
    }
    // 默认学期：名字通用，起始日 = **今天所在那一周的周一**（于是新用户一进来就是"第 1 周"，
    // 而不是看到"第 -37 周"这种尴尬数字），长度 16 周（可在「管理课程 → 学期」里改）。
    const start: string = formatDate(mondayOf(today()));
    const id: number = await TimetableRepo.createSemester(context, DEFAULT_SEMESTER_NAME,
      start, DEFAULT_TOTAL_WEEKS);
    for (const st of DEFAULT_SECTION_TIMES) {
      await TimetableRepo.upsertSectionTime(context, id, st);
    }
    return {
      id: id,
      name: DEFAULT_SEMESTER_NAME,
      startDate: start,
      totalWeeks: DEFAULT_TOTAL_WEEKS,
      firstDayOfWeek: 1,
      showWeekend: true
    };
  }

  static async migrateData(context: common.Context): Promise<number> {
    const estimates: number = await TodoRepo.normalizeAllEstimates(context);
    // 「其他」退役 →「无」（用户 2026-10-15；见 domain/Categories 的文件头）
    const categories: number = await TodoRepo.migrateCategories(context);
    return estimates + categories;
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

  /** 清空一个学期的全部课程（课程 / 时段规则 / 生成模板一起删） */
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
