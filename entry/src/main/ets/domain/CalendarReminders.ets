import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 写进日历事件时打的标记：重新同步时靠它认出「哪些是我们建的」 */
const MARK: string = 'ClassOUT';

/**
 * 一条要写进系统日历的事。
 *
 * 用户 2026-10-30 的要求：不要写「还有 15 分钟上课」那种 15 分钟的小事件，
 * 而是**把课程 / 待办所在的整段时间写成一个日程**，再让日历提前 `leadMin` 分钟提醒。
 * 所以这里带的是事件真正的起止（`at` / `endAt`）和提前量，而不是"该响铃的时刻"。
 */
export interface CalItem {
  /** 事件开始 */
  at: Date;
  /** 事件结束（真实时长；<= at 时按 15 分钟兜底） */
  endAt: Date;
  /** 提前多少分钟提醒（日历的 reminderTime，0 = 准时） */
  leadMin: number;
  /**
   * 是否给这条日历事件设提醒。
   * 已经在进行中的课程/计划块仍然写进日历（用户能在日历里看到"现在这节"），
   * 但不再设提醒，避免每次同步都重复响。
   */
  remind?: boolean;
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
      // 真实时长：课程就是上课时长、计划块就是这块的时长；异常时兜底 15 分钟
      const rawEnd: number = it.endAt.getTime();
      const end: number = rawEnd > start ? rawEnd : start + 15 * 60000;
      const lead: number = it.leadMin < 0 ? 0 : it.leadMin;
      events.push({
        type: calendarManager.EventType.NORMAL,
        title: it.title,
        startTime: start,
        endTime: end,
        // 日历的 reminderTime 单位是分钟：x = 距开始提前 x 分钟提醒（0 = 准时）。
        // 已经开始的条目给空数组：保留日程、不响铃。
        reminderTime: it.remind === false ? [] : [lead],
        // MARK 放末尾：日程备注第一行必须是「截止：…」，不能被识别标记顶到前面。
        // 清理时仍然靠 description 里是否含 MARK 来认领。
        description: `${it.content}\n\n${MARK}`
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
