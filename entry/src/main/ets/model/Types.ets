/**
 * ClassOUT 领域类型
 * 约定：所有时间点用「当天 0 点起的分钟数」表示（0..1440），日期用 'YYYY-MM-DD'。
 */

/** 周次掩码：长度 = 学期总周数，字符 '1' = 该周上课，'0' = 不上 */
export type WeekMask = string;

export interface Semester {
  id: number;
  name: string;
  /** 第一教学周的周一，'YYYY-MM-DD' */
  startDate: string;
  totalWeeks: number;
  /** 1 = 周一是每周第一天 */
  firstDayOfWeek: number;
  showWeekend: boolean;
}

export interface SectionTime {
  section: number;
  startMin: number;
  endMin: number;
  /** true = 机动节次（第 9、12 节），默认不显示网格 */
  flexible: boolean;
}

export interface Course {
  id: number;
  semesterId: number;
  name: string;
  shortName: string;
  teacher: string;
  location: string;
  colorIndex: number;
  /** 是否在这门课下课时自动生成待办 */
  autoTodoEnabled: boolean;
  /** 虚拟课程（CS106L 那种不定时上课的），v1.1 起用 */
  isVirtual: boolean;
  note: string;
}

export interface SessionRule {
  id: number;
  courseId: number;
  /** 1 = 周一 ... 7 = 周日 */
  weekday: number;
  startSection: number;
  endSection: number;
  weeksMask: WeekMask;
  location: string;
  /** 习题课 */
  isQuiz: boolean;
}

/** 只改某一周，不动规则 */
export interface SessionOverride {
  id: number;
  courseId: number;
  /** 原定日期 */
  date: string;
  /** cancel | move | room | extra */
  kind: string;
  newDate: string;
  newStartSection: number;
  newEndSection: number;
  newLocation: string;
}

/** 由规则 + 覆盖层算出来的「某一天的一节课」 */
export interface CourseSession {
  course: Course;
  rule: SessionRule;
  /** 实际发生的日期（被调课后是新的日期） */
  date: string;
  /** 规则原本排定的日期：撤销调整、匹配 override 都靠它 */
  originDate: string;
  weekday: number;
  startSection: number;
  endSection: number;
  startMin: number;
  endMin: number;
  location: string;
  isQuiz: boolean;
  /** 来自覆盖层（调课/加课），用于 UI 区分显示 */
  fromOverride: boolean;
  /**
   * 这节是不是**补课**（`kind = extra`）。
   *
   * 为什么要单独标出来：补课和"调课"共用 `fromOverride`，但两者在「改这一周的地点」时
   * 要改的是**不同的那条覆盖记录**（补课改 extra、调课改 move）。少了这个字段就只能靠
   * `date === originDate` 猜，而"某门课本来就在那天有课、又补了一节"时会猜错。
   */
  isExtra: boolean;
}

export class OverrideKind {
  static readonly Cancel: string = 'cancel';
  static readonly Move: string = 'move';
  static readonly Room: string = 'room';
  static readonly Extra: string = 'extra';
}

/** 北大校本部作息（官方 12 节） */
export const PKU_SECTION_TIMES: SectionTime[] = [
  { section: 1, startMin: 8 * 60, endMin: 8 * 60 + 50, flexible: false },
  { section: 2, startMin: 9 * 60, endMin: 9 * 60 + 50, flexible: false },
  { section: 3, startMin: 10 * 60 + 10, endMin: 11 * 60, flexible: false },
  { section: 4, startMin: 11 * 60 + 10, endMin: 12 * 60, flexible: false },
  { section: 5, startMin: 13 * 60, endMin: 13 * 60 + 50, flexible: false },
  { section: 6, startMin: 14 * 60, endMin: 14 * 60 + 50, flexible: false },
  { section: 7, startMin: 15 * 60 + 10, endMin: 16 * 60, flexible: false },
  { section: 8, startMin: 16 * 60 + 10, endMin: 17 * 60, flexible: false },
  { section: 9, startMin: 17 * 60 + 10, endMin: 18 * 60, flexible: true },
  { section: 10, startMin: 18 * 60 + 40, endMin: 19 * 60 + 30, flexible: false },
  { section: 11, startMin: 19 * 60 + 40, endMin: 20 * 60 + 30, flexible: false },
  { section: 12, startMin: 20 * 60 + 40, endMin: 21 * 60 + 30, flexible: true }
];

/**
 * 课程配色（**深底 + 白字**）。
 *
 * ⚠️ 2026-10-14 深色主题改造：原来是 10 个**浅色粉彩**（配合深字用的）。
 * 全 App 文字翻成浅色之后，「浅色块 + 浅字」就看不清了，所以整组换成深色调 ——
 * 压 `#F2F5FA`（主文字色）上去要能读清，同时保住"一眼认出是哪门课"的辨识度。
 *
 * 它被用在四处，改这里四处一起变：课表格子、课表页/待办页的课程胶囊、
 * 计划页的块与待安排托盘卡、管理课程的课程列表。
 */
export const COURSE_COLORS: string[] = [
  '#8A6B1F', // 黄（深金）
  '#2F7D4F', // 绿
  '#2C5FA8', // 蓝
  '#6B45A8', // 紫
  '#1F7A73', // 青
  '#A8452F', // 珊瑚
  '#8A3D6B', // 粉（品红）
  '#4A5B75', // 灰蓝
  '#7A6A2F', // 卡其
  '#4F7A2F'  // 草绿
];

/** 缺省不可排时段（用户可改） */
export interface RestWindow {
  id: number;
  /** 0 = 每天；1..7 = 周一..周日 */
  weekday: number;
  startMin: number;
  endMin: number;
  label: string;
}

export const DEFAULT_REST_WINDOWS: RestWindow[] = [
  { id: 0, weekday: 0, startMin: 12 * 60, endMin: 13 * 60, label: '午休' },
  { id: 0, weekday: 0, startMin: 17 * 60, endMin: 18 * 60 + 30, label: '晚饭' },
  { id: 0, weekday: 0, startMin: 23 * 60 + 30, endMin: 24 * 60, label: '睡觉' },
  { id: 0, weekday: 0, startMin: 0, endMin: 7 * 60, label: '睡觉' }
];

/** 待办状态 */
export class TodoStatus {
  /** 自动生成、等用户确认 */
  static readonly Pending: string = 'pending';
  static readonly Active: string = 'active';
  static readonly Done: string = 'done';
  static readonly Archived: string = 'archived';
}

export class TodoCategory {
  static readonly Homework: string = 'homework';
  static readonly Self: string = 'self';
  static readonly Exam: string = 'exam';
  static readonly Other: string = 'other';
}

export class TodoSource {
  static readonly Manual: string = 'manual';
  static readonly Template: string = 'template';
}

export interface Todo {
  id: number;
  title: string;
  /** 0 = 不属于任何课程 */
  courseId: number;
  category: string;
  priority: number;
  /** '' = 无截止时间；否则 'YYYY-MM-DD HH:mm' */
  ddl: string;
  /**
   * **考试专用**：考试结束时刻（'YYYY-MM-DD HH:mm'），其它类型恒为 ''。
   * 开始时刻就存在 `ddl` 里 —— 这样倒计时、提醒、截止标记这一整套都不用改。
   * 有它才知道考试在计划视图里该占多长一段（见 Validate.examRangeOf）。
   */
  endAt: string;
  estimateMin: number;
  status: string;
  source: string;
  /** 去重键：courseId|date|templateId */
  generationKey: string;
  note: string;
  submitChannel: string;
  repeatRule: string;
  photos: string;
  createdAt: number;
  confirmedAt: number;
  doneAt: number;
}

export interface TodoTemplate {
  id: number;
  courseId: number;
  sortOrder: number;
  enabled: boolean;
  /** 支持 %C %c %D %d %W %T %N %R */
  titleTemplate: string;
  /** none | same_day | days | next_session | week_end | weekday */
  ddlRule: string;
  /** days: '3'；weekday: '7'；next_session 无参 */
  ddlParam: string;
  estimateMin: number;
  category: string;
  submitChannel: string;
  note: string;
}

export interface PlanBlock {
  id: number;
  /** 普通待办排的块（0 = 不是待办） */
  todoId: number;
  /** 虚拟课程课时排的块（0 = 不是课时） */
  lessonId: number;
  date: string;
  startMin: number;
  endMin: number;
  done: boolean;
}

/**
 * 虚拟课程的课时。
 * 虚拟课程没有固定上课时间，它就是「一串等着被分配的课时」——
 * 整体看上去像一个大待办，每一讲排进计划并完成时，就跟真课下课一样触发生成模板。
 */
export interface VirtualLesson {
  id: number;
  courseId: number;
  /** 第几讲，从 1 开始 */
  seq: number;
  title: string;
  done: boolean;
  doneAt: number;
}
