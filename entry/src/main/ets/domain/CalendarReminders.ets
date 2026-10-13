import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 写进日历事件时打的标记：重新同步时靠它认出「哪些是我们建的」 */
const MARK: string = 'ClassOUT';

/** 一条要提醒的事（时间 + 标题 + 说明） */
export interface CalItem {
  at: Date;
  title: string;
  content: string;
}

export interface CalendarPlan {
  granted: boolean;
  removed: number;
  added: number;
}

/**
 * 申请日历读写权限（两者都是 normal + user_grant，会弹系统授权框）。
 */
export async function ensureCalendarPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const perms: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
    const result = await atManager.requestPermissionsFromUser(context, perms);
    const results: number[] = result.authResults;
    for (const r of results) {
      if (r !== 0) {
        return false;
      }
    }
    return true;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'calendar permission failed: %{public}s', JSON.stringify(e));
    return false;
  }
}

/**
 * 把提醒写进系统日历，由系统日历负责响铃。
 *
 * 为什么需要这条路：鸿蒙的「代理提醒」对普通侧载应用上限是 0 条
 * （实测 publishReminder 一律返回 1700002），而拿「代理提醒特权」需要过审，个人应用没有入口。
 * 系统日历没有条数上限、不依赖应用存活，是唯一能让提醒真正响起来的办法。
 * 代价：事件会出现在你的系统日历里 —— 对课表/作业来说这通常反而是好事。
 */
export async function syncCalendarReminders(context: common.UIAbilityContext,
  items: CalItem[]): Promise<CalendarPlan> {
  const plan: CalendarPlan = { granted: false, removed: 0, added: 0 };
  const granted: boolean = await ensureCalendarPermission(context);
  plan.granted = granted;
  if (!granted) {
    hilog.warn(DOMAIN, TAG, '%{public}s', 'calendar permission denied, skip');
    return plan;
  }

  try {
    const mgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
    const cal: calendarManager.Calendar = await mgr.getCalendar();

    // 先清掉上一轮我们自己建的，避免每次启动都堆一份
    const existing: calendarManager.Event[] = await cal.getEvents();
    const doomed: number[] = [];
    for (const e of existing) {
      const desc: string | undefined = e.description;
      const id: number | undefined = e.id;
      if (desc !== undefined && id !== undefined && desc.indexOf(MARK) >= 0) {
        doomed.push(id);
      }
    }
    if (doomed.length > 0) {
      await cal.deleteEvents(doomed);
      plan.removed = doomed.length;
    }

    // 再按当前窗口重排
    const events: calendarManager.Event[] = [];
    for (const it of items) {
      const start: number = it.at.getTime();
      events.push({
        type: calendarManager.EventType.NORMAL,
        title: it.title,
        startTime: start,
        endTime: start + 15 * 60000,
        reminderTime: [0],
        description: `${MARK}｜${it.content}`
      });
    }
    if (events.length > 0) {
      await cal.addEvents(events);
      plan.added = events.length;
    }
    hilog.info(DOMAIN, TAG, 'calendar reminders: removed=%{public}d added=%{public}d',
      plan.removed, plan.added);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'calendar sync failed: %{public}s', JSON.stringify(e));
  }
  return plan;
}
