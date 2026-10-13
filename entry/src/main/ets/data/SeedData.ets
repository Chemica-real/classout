/**
 * 种子数据
 *
 * ⚠️ 来源：用户 2026-10-13 的课表截图（人工转录），**必须由用户逐条核对**。
 * 用途：首次启动时把课表和作息预填进去，免得从零手录 15 分钟。
 * 不确定的两条（习题课时间）已在字段里标注。
 */

export interface SeedRule {
  weekday: number;
  startSection: number;
  endSection: number;
  isQuiz: boolean;
}

export interface SeedTemplate {
  title: string;
  /** none | same_day | days | next_session | week_end | weekday */
  ddlRule: string;
  ddlParam: string;
  estimateMin: number;
}

export interface SeedCourse {
  name: string;
  shortName: string;
  teacher: string;
  location: string;
  colorIndex: number;
  /** 体育/艺术类等不布置书面作业的课，留空 */
  templates: SeedTemplate[];
  rules: SeedRule[];
}

export const SEED_SEMESTER_NAME: string = '大一上';
/** 2026-2027 秋季学期第一教学周周一（北大校历：9/7 星期一开课） */
export const SEED_START_DATE: string = '2026-09-07';
export const SEED_TOTAL_WEEKS: number = 16;

/** %D 作业，截止 = 最近的星期 N 的 23:59（含当天） */
function homeworkWeekday(weekday: number): SeedTemplate[] {
  return [{ title: '%D作业', ddlRule: 'weekday', ddlParam: `${weekday}`, estimateMin: 90 }];
}

/** %D 作业，截止 = 下一次同门课当天 23:59 */
function homeworkNextSession(): SeedTemplate[] {
  return [{ title: '%D作业', ddlRule: 'next_session', ddlParam: '', estimateMin: 90 }];
}

export const SEED_COURSES: SeedCourse[] = [
  {
    name: '课程甲', shortName: '课甲', teacher: '老师甲', location: '教学楼407', colorIndex: 0,
    // 截图实证：课甲 的作业截止恒为周三 23:59（下一次课是周三的习题课）
    templates: homeworkWeekday(3),
    rules: [
      { weekday: 2, startSection: 1, endSection: 2, isQuiz: false },
      { weekday: 4, startSection: 3, endSection: 4, isQuiz: false }
    ]
  },
  {
    name: '课程乙', shortName: '课乙', teacher: '老师丙', location: '教学楼309', colorIndex: 1,
    // 截图实证：课乙作业截止为周四 23:59
    templates: homeworkWeekday(4),
    rules: [
      { weekday: 2, startSection: 3, endSection: 4, isQuiz: false },
      { weekday: 4, startSection: 1, endSection: 2, isQuiz: false }
    ]
  },
  {
    name: '课程丙', shortName: '课丙', teacher: '老师戊、老师己', location: '教学楼109',
    colorIndex: 2,
    // 截图实证：课丙作业截止为下周一 23:59
    templates: homeworkWeekday(1),
    rules: [
      { weekday: 1, startSection: 5, endSection: 6, isQuiz: false },
      { weekday: 3, startSection: 3, endSection: 4, isQuiz: false }
    ]
  },
  {
    name: '课程丁', shortName: '课丁', teacher: '老师庚、老师辛', location: '教学楼101',
    colorIndex: 3,
    // 截图里课丁的 ddl 落在周日 23:59
    templates: [{ title: '%D作业', ddlRule: 'week_end', ddlParam: '', estimateMin: 60 }],
    rules: [
      { weekday: 1, startSection: 7, endSection: 8, isQuiz: false }
    ]
  },
  {
    name: '课程戊', shortName: '课戊', teacher: '老师壬', location: '在线', colorIndex: 4,
    templates: homeworkNextSession(),
    rules: [
      { weekday: 3, startSection: 5, endSection: 6, isQuiz: false },
      { weekday: 5, startSection: 3, endSection: 4, isQuiz: false }
    ]
  },
  {
    name: '课程己', shortName: '课己', teacher: '老师癸、老师子', location: '教学楼203',
    colorIndex: 5,
    templates: homeworkNextSession(),
    rules: [
      { weekday: 2, startSection: 5, endSection: 6, isQuiz: false }
    ]
  },
  {
    name: '课程庚', shortName: '课庚', teacher: '', location: '教学楼108', colorIndex: 6,
    templates: homeworkNextSession(),
    rules: [
      { weekday: 3, startSection: 7, endSection: 8, isQuiz: false }
    ]
  },
  {
    name: '课程辛', shortName: '课程辛', teacher: '老师丑', location: '体育馆', colorIndex: 7,
    templates: [],
    rules: [
      { weekday: 5, startSection: 5, endSection: 6, isQuiz: false }
    ]
  },
  {
    name: '课程壬', shortName: '课壬', teacher: '', location: '', colorIndex: 8,
    templates: [],
    rules: [
      { weekday: 5, startSection: 7, endSection: 8, isQuiz: false }
    ]
  },
  {
    // 已核对：截图第 10 节左侧那块在「周三」列；北大官方固定排课也是「课程甲习题课 周三10-11」
    name: '课程甲习题课', shortName: '课甲习题', teacher: '老师乙', location: '教学楼408',
    colorIndex: 9,
    templates: [],
    rules: [
      { weekday: 3, startSection: 10, endSection: 10, isQuiz: true }
    ]
  },
  {
    // 已核对：截图第 10 节右侧那块在「周四」列
    name: '课程乙习题课', shortName: '课乙习题', teacher: '老师丁', location: '教学楼406',
    colorIndex: 1,
    templates: [],
    rules: [
      { weekday: 4, startSection: 10, endSection: 10, isQuiz: true }
    ]
  }
];
