import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Course, PlanBlock, Semester, SessionRule, Todo, TodoCategory, TodoSource,
  TodoStatus, TodoTemplate } from '../model/Types';
import { TimetableRepo } from './TimetableRepo';
import { TodoRepo } from './TodoRepo';
import { Seeder } from './Seeder';
import { Db } from './Db';
import { DB_NAME, DEMO_DB_NAME } from './Schema';
import { maskAll } from '../model/WeekMask';
import { addDays, formatDate, today } from '../util/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 沙箱里的学期名（一眼能看出这不是自己的课表；短一点，免得课表页头折行） */
export const DEMO_SEMESTER_NAME: string = '演练学期';

/** 首次启动询问过没有（写在**真实库**的 kv 里） */
export const GUIDE_PROMPT_KV: string = 'guide_prompted';

interface DemoCourseSpec {
  name: string;
  shortName: string;
  teacher: string;
  location: string;
  colorIndex: number;
  /** [weekday, startSection, endSection, isQuiz] */
  rules: number[][];
}

/**
 * 演练用的 4 门演示课。刻意用通用的名字（和 README 的示例一致），
 * 不带任何真人/真课信息。
 */
const DEMO_COURSES: DemoCourseSpec[] = [
  {
    name: '高等数学', shortName: '高数', teacher: '王老师', location: '教学楼101', colorIndex: 2,
    rules: [[1, 1, 2, 0], [3, 3, 4, 0], [3, 10, 11, 1]]
  },
  {
    name: '大学英语', shortName: '英语', teacher: '李老师', location: '外语楼203', colorIndex: 1,
    rules: [[2, 5, 6, 0]]
  },
  {
    name: '计算机导论', shortName: '计导', teacher: '张老师', location: '理科楼305', colorIndex: 3,
    rules: [[4, 7, 8, 0]]
  },
  {
    name: '线性代数', shortName: '线代', teacher: '刘老师', location: '教学楼408', colorIndex: 0,
    rules: [[5, 3, 4, 0]]
  }
];

/**
 * 「新手演练」的沙箱生命周期。
 *
 * 设计（用户 2026-10-15 拍定「真实操作真写库、退出后自己的数据一点不变」）：
 * - **整库切换**：演练期间连 `classout_demo.db`，真实库 `classout.db` 全程不被打开。
 *   比"在真实库里建个演示学期"干净得多 —— 待办表没有学期字段，塞进去会和真实待办混在一起。
 * - 进：切库 → 建学期/作息 → 灌演示数据。
 * - 出：切回真实库 → 删掉沙箱文件。
 * - **中断**（演练中 App 被杀）：进程重启后 `Db.activeName` 回到真实库，
 *   沙箱文件变成垃圾 → 冷启动时 `cleanupDemoFile()` 顺手删掉。真实数据始终安然无恙。
 */
export class GuideRepo {

  /** 冷启动清理：进程重启后沙箱文件一定没用了（`Db` 默认连真实库） */
  static async cleanupDemoFile(context: common.Context): Promise<void> {
    try {
      await relationalStore.deleteRdbStore(context, DEMO_DB_NAME);
      hilog.info(DOMAIN, TAG, 'demo sandbox db deleted: %{public}s', DEMO_DB_NAME);
    } catch (e) {
      // 不存在是常态（没进过演练 / 退出时已经删过），不值得报错
    }
  }

  /** 首次启动的那句询问问过没有 */
  static async guidePrompted(context: common.Context): Promise<boolean> {
    return (await Db.getKv(context, GUIDE_PROMPT_KV)) === '1';
  }

  /** 记下"问过了"（在**切库之前**写，写的才是真实库） */
  static async markPrompted(context: common.Context): Promise<void> {
    await Db.setKv(context, GUIDE_PROMPT_KV, '1');
  }

  /**
   * 进沙箱：切到演示库并灌好演示数据。返回沙箱里的学期。
   * ⚠️ 调用前请先把要留在真实库里的东西（比如"问过了"）写完。
   */
  static async startDemo(context: common.Context): Promise<Semester> {
    await Db.use(context, DEMO_DB_NAME);
    const sem: Semester = await Seeder.ensureSemester(context);
    if (sem.name !== DEMO_SEMESTER_NAME) {
      sem.name = DEMO_SEMESTER_NAME;
      await TimetableRepo.updateSemester(context, sem);
    }
    await Seeder.ensureRestWindows(context);
    await GuideRepo.seedDemoData(context, sem);
    return sem;
  }

  /** 出沙箱：切回真实库并把演示库删掉 */
  static async exitDemo(context: common.Context): Promise<void> {
    await Db.use(context, DB_NAME);
    await GuideRepo.cleanupDemoFile(context);
  }

  /**
   * 灌演示数据（幂等：已经有课程就直接返回）。
   *
   * 内容：4 门课 + 时段规则（含一节习题课）+ 每门课一条生成模板 +
   * 4 条待办（覆盖"有/无截止""有/无课程""有/无备注"）+ 2 个已排的计划块。
   * 这样待办页、计划页一进去就有东西可点，不用先自己建。
   */
  private static async seedDemoData(context: common.Context, sem: Semester): Promise<void> {
    const existing: Course[] = await TimetableRepo.listCourses(context, sem.id);
    if (existing.length > 0) {
      return;
    }
    const fullMask: string = maskAll(sem.totalWeeks);
    const ids: number[] = [];
    for (const spec of DEMO_COURSES) {
      const course: Course = {
        id: 0,
        semesterId: sem.id,
        name: spec.name,
        shortName: spec.shortName,
        teacher: spec.teacher,
        location: spec.location,
        colorIndex: spec.colorIndex,
        autoTodoEnabled: true,
        isVirtual: false,
        note: ''
      };
      const cid: number = await TimetableRepo.insertCourse(context, course);
      ids.push(cid);
      for (const r of spec.rules) {
        const rule: SessionRule = {
          id: 0,
          courseId: cid,
          weekday: r[0],
          startSection: r[1],
          endSection: r[2],
          weeksMask: fullMask,
          location: '',
          isQuiz: r[3] === 1
        };
        await TimetableRepo.insertRule(context, rule);
      }
      const tpl: TodoTemplate = {
        id: 0,
        courseId: cid,
        sortOrder: 0,
        enabled: true,
        titleTemplate: '%D作业',
        ddlRule: 'next_session',
        ddlParam: '',
        estimateMin: 60,
        category: TodoCategory.Homework,
        submitChannel: '',
        note: ''
      };
      await TodoRepo.insertTemplate(context, tpl);
    }

    const day0: string = formatDate(today());
    const day1: string = formatDate(addDays(today(), 1));
    const day3: string = formatDate(addDays(today(), 3));
    const todoIds: number[] = [];
    todoIds.push(await GuideRepo.insertDemoTodo(context, '数学作业 P12 第 3-5 题', ids[0],
      `${day0} 23:59`, 60, TodoCategory.Homework, '记得写过程'));
    todoIds.push(await GuideRepo.insertDemoTodo(context, '背 20 个单词', ids[1],
      `${day1} 23:59`, 30, TodoCategory.Self, ''));
    todoIds.push(await GuideRepo.insertDemoTodo(context, '预习第 2 章', ids[2],
      '', 45, TodoCategory.Homework, ''));
    todoIds.push(await GuideRepo.insertDemoTodo(context, '买笔记本', 0,
      `${day3} 23:59`, 15, TodoCategory.None, '顺手买支笔'));

    // 已排的计划块：一条在"今天下午"，一条在"明天早上"
    await GuideRepo.insertDemoBlock(context, todoIds[0], day0, 14 * 60, 15 * 60);
    await GuideRepo.insertDemoBlock(context, todoIds[1], day1, 9 * 60, 9 * 60 + 30);
  }

  private static async insertDemoTodo(context: common.Context, title: string, courseId: number,
    ddl: string, estimateMin: number, category: string, note: string): Promise<number> {
    const t: Todo = {
      id: 0,
      title: title,
      courseId: courseId,
      category: category,
      priority: 1,
      ddl: ddl,
      endAt: '',
      estimateMin: estimateMin,
      status: TodoStatus.Active,
      source: TodoSource.Manual,
      generationKey: '',
      note: note,
      submitChannel: '',
      repeatRule: '',
      photos: '',
      createdAt: Date.now(),
      confirmedAt: Date.now(),
      doneAt: 0
    };
    return await TodoRepo.insertTodo(context, t);
  }

  private static async insertDemoBlock(context: common.Context, todoId: number, date: string,
    startMin: number, endMin: number): Promise<void> {
    const b: PlanBlock = {
      id: 0,
      todoId: todoId,
      lessonId: 0,
      date: date,
      startMin: startMin,
      endMin: endMin,
      done: false
    };
    await TodoRepo.insertBlock(context, b);
  }
}
