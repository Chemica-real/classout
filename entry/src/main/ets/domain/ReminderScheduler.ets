import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Course, CourseSession, PlanBlock, Semester, SessionOverride, SessionRule, SectionTime,
  Todo, TodoCategory, TodoStatus, VirtualLesson } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { Db } from '../data/Db';
import { computeWeekSessions, weekOfDate } from './Timetable';
import { buildBriefing } from './Briefing';
import { CalItem, CalendarPlan, syncCalendarReminders } from './CalendarReminders';
import { addDays, formatDate, minToHHmm, parseDate, today } from '../util/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

const PKG: string = 'com.chemica.classout';
const ABILITY: string = 'EntryAbility';

/** 滚动窗口：未来多少天 */
export const WINDOW_DAYS: number = 7;
/** 计划块提醒只看未来几天（块变动频繁，窗口长了纯浪费配额） */
const BLOCK_WINDOW_DAYS: number = 3;
/** 代理提醒总预算。API 26 上限 64，留余量 */
export const REMINDER_BUDGET: number = 60;
const NOTIFICATION_ID_BASE: number = 1000;

const KV_BRIEF_ENABLED: string = 'brief_enabled';
const KV_BRIEF_TIME: string = 'brief_time';
const KV_CLASS_LEAD: string = 'class_lead';

export const DEFAULT_BRIEF_MIN: number = 7 * 60 + 30;
export const DEFAULT_CLASS_LEAD_MIN: number = 15;

export interface ReminderSettings {
  /** 每天早上一条简报 */
  briefEnabled: boolean;
  /** 简报时间（当天 0 点起的分钟数） */
  briefMin: number;
  /** 上课提前量（分钟） */
  classLeadMin: number;
}

export async function loadReminderSettings(context: common.Context): Promise<ReminderSettings> {
  const enabledRaw: string = await Db.getKv(context, KV_BRIEF_ENABLED);
  const timeRaw: string = await Db.getKv(context, KV_BRIEF_TIME);
  const leadRaw: string = await Db.getKv(context, KV_CLASS_LEAD);

  let briefMin: number = DEFAULT_BRIEF_MIN;
  if (timeRaw.length === 5) {
    const h: number = parseInt(timeRaw.substring(0, 2), 10);
    const m: number = parseInt(timeRaw.substring(3, 5), 10);
    if (!isNaN(h) && !isNaN(m)) {
      briefMin = h * 60 + m;
    }
  }
  let lead: number = DEFAULT_CLASS_LEAD_MIN;
  const leadNum: number = parseInt(leadRaw, 10);
  if (!isNaN(leadNum) && leadNum >= 0 && leadNum <= 120) {
    lead = leadNum;
  }
  return {
    briefEnabled: enabledRaw.length === 0 ? true : enabledRaw === '1',
    briefMin: briefMin,
    classLeadMin: lead
  };
}

export async function saveReminderSettings(context: common.Context,
  s: ReminderSettings): Promise<void> {
  await Db.setKv(context, KV_BRIEF_ENABLED, s.briefEnabled ? '1' : '0');
  await Db.setKv(context, KV_BRIEF_TIME, minToHHmm(s.briefMin));
  await Db.setKv(context, KV_CLASS_LEAD, `${s.classLeadMin}`);
}

interface Candidate {
  at: Date;
  title: string;
  content: string;
  kind: string;
}

export interface ReminderPlan {
  classes: number;
  ddl: number;
  blocks: number;
  briefs: number;
  published: number;
  skippedByBudget: number;
  enabled: boolean;
  /** 代理提醒全被拒时，改写到系统日历的事件数 */
  calendarEvents: number;
}

function atTime(day: Date, hour: number, minute: number): Date {
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute);
}

/** 把 ddl 字符串 'YYYY-MM-DD HH:mm' 变成本地 Date */
function ddlDate(ddl: string): Date | undefined {
  if (ddl.length < 16) {
    return undefined;
  }
  const y: number = parseInt(ddl.substring(0, 4), 10);
  const mo: number = parseInt(ddl.substring(5, 7), 10);
  const d: number = parseInt(ddl.substring(8, 10), 10);
  const h: number = parseInt(ddl.substring(11, 13), 10);
  const mi: number = parseInt(ddl.substring(14, 16), 10);
  return new Date(y, mo - 1, d, h, mi);
}

/** 通知权限：没开就请求一次 */
async function ensureNotification(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const enabled: boolean = await notificationManager.isNotificationEnabled();
    if (enabled) {
      return true;
    }
    await notificationManager.requestEnableNotification(context);
    return await notificationManager.isNotificationEnabled();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'notification permission failed: %{public}s', JSON.stringify(e));
    return false;
  }
}

/** 某天的简报正文：今天几节课 + 今天截止什么（实现在 domain/Briefing.ets，纯函数可离线验证） */

/**
 * 全量重排提醒。
 *
 * 为什么是「重排」而不是增量：代理提醒是唯一能在 App 关闭时精确触发的手段，
 * 但每个应用只有 64 条上限，所以每次启动都把旧的全部撤掉、按当前课表和待办重排一个滚动窗口。
 * 代价：如果超过窗口天数不打开 App，窗口外的提醒不会响。
 */
export async function syncReminders(context: common.UIAbilityContext,
  sem: Semester): Promise<ReminderPlan> {
  const plan: ReminderPlan = {
    classes: 0, ddl: 0, blocks: 0, briefs: 0, published: 0, skippedByBudget: 0,
    enabled: false, calendarEvents: 0
  };

  const enabled: boolean = await ensureNotification(context);
  plan.enabled = enabled;

  // 先撤掉本应用所有有效提醒（避免重复响铃）
  try {
    await reminderAgentManager.cancelAllReminders();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'cancel reminders failed: %{public}s', JSON.stringify(e));
  }

  if (!enabled) {
    return plan;
  }

  const settings: ReminderSettings = await loadReminderSettings(context);
  const courses: Course[] = await TimetableRepo.listCourses(context, sem.id);
  const rules: SessionRule[] = await TimetableRepo.listRules(context, sem.id);
  const times: SectionTime[] = await TimetableRepo.listSectionTimes(context, sem.id);
  const todos: Todo[] = await TodoRepo.listTodos(context, 'status = ?', [TodoStatus.Active]);
  const lessons: VirtualLesson[] = await TodoRepo.listLessonsOfVirtualCourses(context, sem.id);
  const now: Date = new Date();

  const courseMap: Map<number, Course> = new Map<number, Course>();
  for (const c of courses) {
    courseMap.set(c.id, c);
  }
  const candidates: Candidate[] = [];

  // ---------- 上课前提醒 + 每日简报 ----------
  for (let offset = 0; offset <= WINDOW_DAYS; offset++) {
    const d: Date = addDays(today(), offset);
    const week: number = weekOfDate(sem, d);
    if (week < 1 || week > sem.totalWeeks) {
      continue;
    }
    const dateStr: string = formatDate(d);
    const overrides: SessionOverride[] =
      await TimetableRepo.listOverridesBetween(context, dateStr, dateStr);
    const weekSessions: CourseSession[] =
      computeWeekSessions(sem, courses, rules, overrides, times, week);
    const daySessions: CourseSession[] = [];
    for (const s of weekSessions) {
      if (s.date === dateStr) {
        daySessions.push(s);
      }
    }

    for (const s of daySessions) {
      const startAt: Date = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
        Math.floor(s.startMin / 60), s.startMin % 60);
      const remindAt: Date = new Date(startAt.getTime() - settings.classLeadMin * 60000);
      if (remindAt.getTime() <= now.getTime()) {
        continue;
      }
      const name: string = s.course.shortName.length > 0 ? s.course.shortName : s.course.name;
      candidates.push({
        at: remindAt,
        title: `${name} 还有 ${settings.classLeadMin} 分钟上课`,
        content: `${s.location.length > 0 ? s.location : '教室待定'}${s.course.teacher.length > 0 ? ' · ' + s.course.teacher : ''}`,
        kind: 'class'
      });
      plan.classes++;
    }

    if (settings.briefEnabled) {
      const briefAt: Date = atTime(d, Math.floor(settings.briefMin / 60), settings.briefMin % 60);
      if (briefAt.getTime() > now.getTime()) {
        candidates.push({
          at: briefAt,
          title: '今日简报',
          content: buildBriefing(dateStr, daySessions, todos),
          kind: 'brief'
        });
        plan.briefs++;
      }
    }
  }

  // ---------- 作业截止提醒：前一天 20:00；若已过则退化为截止前 2 小时 ----------
  for (const t of todos) {
    // ⚠️ **考试不排「即将截止」**：考试的 ddl 存的是它的**开始时刻**（见 Types.Todo.endAt），
    //    排成"XX 即将截止"语义就错了。用户 2026-10-16 的原话是「考试无需显示截止」，
    //    当时改了计划网格的 ⚑ 标记、计划块属性面板、每日简报三处，**漏了这里**。
    //    考试的提醒交给它的计划块（syncExamBlock 会建块 → "该做「XX」了"）。
    if (t.category === TodoCategory.Exam) {
      continue;
    }
    const due: Date | undefined = ddlDate(t.ddl);
    if (due === undefined || due.getTime() <= now.getTime()) {
      continue;
    }
    let at: Date = atTime(addDays(due, -1), 20, 0);
    if (at.getTime() <= now.getTime()) {
      at = new Date(due.getTime() - 2 * 3600000);
    }
    if (at.getTime() <= now.getTime()) {
      continue;
    }
    if (at.getTime() - now.getTime() > WINDOW_DAYS * 86400000) {
      continue;
    }
    const course: Course | undefined = courseMap.get(t.courseId);
    candidates.push({
      at: at,
      title: `${t.title} 即将截止`,
      content: `截止 ${t.ddl}${course !== undefined ? ' · ' + course.name : ''}`,
      kind: 'ddl'
    });
    plan.ddl++;
  }

  // ---------- 计划块到点提醒 ----------
  for (let offset = 0; offset <= BLOCK_WINDOW_DAYS; offset++) {
    const d: Date = addDays(today(), offset);
    const dateStr: string = formatDate(d);
    const blocks: PlanBlock[] = await TodoRepo.listBlocksOn(context, dateStr);
    for (const b of blocks) {
      if (b.done) {
        continue;
      }
      const at: Date = new Date(d.getFullYear(), d.getMonth(), d.getDate(),
        Math.floor(b.startMin / 60), b.startMin % 60);
      if (at.getTime() <= now.getTime()) {
        continue;
      }
      let title: string = '该做这件事了';
      if (b.lessonId > 0) {
        for (const l of lessons) {
          if (l.id === b.lessonId) {
            const c: Course | undefined = courseMap.get(l.courseId);
            const name: string = c === undefined ? '虚拟课程'
              : (c.shortName.length > 0 ? c.shortName : c.name);
            title = `该上「${name} 第 ${l.seq} 讲」了`;
          }
        }
      } else {
        for (const t of todos) {
          if (t.id === b.todoId) {
            title = `该做「${t.title}」了`;
          }
        }
      }
      candidates.push({
        at: at,
        title: title,
        content: `计划 ${minToHHmm(b.startMin)}-${minToHHmm(b.endMin)}`,
        kind: 'block'
      });
      plan.blocks++;
    }
  }

  // ---------- 按时间升序，按预算截断（早的先保） ----------
  candidates.sort((a: Candidate, b: Candidate): number => a.at.getTime() - b.at.getTime());
  let index: number = 0;
  for (const c of candidates) {
    if (plan.published >= REMINDER_BUDGET) {
      plan.skippedByBudget++;
      continue;
    }
    const request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: c.at.getFullYear(),
        month: c.at.getMonth() + 1,
        day: c.at.getDate(),
        hour: c.at.getHours(),
        minute: c.at.getMinutes()
      },
      title: c.title,
      content: c.content,
      notificationId: NOTIFICATION_ID_BASE + index,
      // 用 SERVICE_INFORMATION（同样是高优先级）而不是 SOCIAL_COMMUNICATION：
      // 后者是给 IM 类应用的，第三方工具应用发上去可能被判权限不足。
      slotType: notificationManager.SlotType.SERVICE_INFORMATION,
      wantAgent: {
        pkgName: PKG,
        abilityName: ABILITY
      },
      ringDuration: 5,
      snoozeTimes: 0
    };
    try {
      await reminderAgentManager.publishReminder(request);
      plan.published++;
      index++;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'publish reminder failed: %{public}s', JSON.stringify(e));
    }
  }

  hilog.info(DOMAIN, TAG,
    'reminders synced: published=%{public}d class=%{public}d ddl=%{public}d block=%{public}d brief=%{public}d skipped=%{public}d',
    plan.published, plan.classes, plan.ddl, plan.blocks, plan.briefs, plan.skippedByBudget);

  // 代理提醒一条都没发出去（普通侧载应用上限为 0，实测 1700002）→ 改用系统日历承载
  if (plan.published === 0 && candidates.length > 0) {
    hilog.warn(DOMAIN, TAG, '%{public}s',
      'agent reminder unavailable, falling back to system calendar');
    const items: CalItem[] = [];
    for (const c of candidates) {
      items.push({ at: c.at, title: c.title, content: c.content });
    }
    const calPlan: CalendarPlan = await syncCalendarReminders(context, items);
    plan.calendarEvents = calPlan.added;
  }

  return plan;
}
