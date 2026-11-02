/**
 * 新手演练的**步骤脚本**（纯数据 + 纯函数，进离线断言）。
 *
 * 用户 2026-10-15：「能不能做一个新手引导，可以是在沙箱里使用，你步步引导」。
 * 追问后拍定：**引导条模式** —— 建一个沙箱库、在**真实界面**上挂一条步骤条，
 * 每一步说明 + 自动切到对应的标签页，用户照着做，做的每一下都真实落库（落到沙箱里）。
 *
 * 为什么步骤文案放在 domain 层：它是一份**内容**，改文案不该碰 `Index` 的逻辑；
 * 而且「每一步对应哪个标签页、有没有越界」这种能离线断言，比在真机上点一遍便宜得多。
 *
 * ⚠️ 文案请保持"说人话 + 说清楚"：目标用户是**编程新手**（HANDOFF §11）。
 */

export interface GuideStep {
  /** 步骤标题（引导条上那行加粗的） */
  title: string;
  /** 这一步要做什么（引导条下面的正文，可两三句） */
  body: string;
  /** 这一步该在哪个标签页：0 课表 / 1 待办 / 2 计划 / 3 设置 */
  tab: number;
}

/** 标签页编号（和 Index 的 `tab` 一致） */
export class GuideTab {
  static readonly Timetable: number = 0;
  static readonly Todo: number = 1;
  static readonly Plan: number = 2;
  static readonly Settings: number = 3;
}

export function guideSteps(): GuideStep[] {
  return [
    {
      title: '先看课表',
      body: '演练里已经放好 4 门演示课；接下来每一步都只改沙箱，不会动你的真实数据。',
      tab: GuideTab.Timetable
    },
    {
      title: '点一节课',
      body: '点任意一个课程色块，看弹出的单周调整面板。',
      tab: GuideTab.Timetable
    },
    {
      title: '换一次教室',
      body: '把「换教室」改个地点，点「换到这儿」；课表上的地点会当场变化。',
      tab: GuideTab.Timetable
    },
    {
      title: '待办分成几段',
      body: '切到「待办」：今天 / 已逾期 / 以后 / 已完成。表头都可以点开或收起。',
      tab: GuideTab.Todo
    },
    {
      title: '打勾完成一条',
      body: '点待办最左边的圆圈；它会去「已完成」，还能恢复或删除。',
      tab: GuideTab.Todo
    },
    {
      title: '新建一条待办',
      body: '点底部「＋ 新建待办」：填标题、类型、截止时间，最后保存。',
      tab: GuideTab.Todo
    },
    {
      title: '排序和折叠',
      body: '顶部「排序」可在截止时间和标题之间切换；点分组表头可以折叠。',
      tab: GuideTab.Todo
    },
    {
      title: '左滑删除',
      body: '在待办上向左滑会出现红色删除；松手后先确认。演练里点「取消」就好。',
      tab: GuideTab.Todo
    },
    {
      title: '打开待安排',
      body: '切到「计划」，点开底部的「待安排」；里面是还没排时间的待办。',
      tab: GuideTab.Plan
    },
    {
      title: '排进网格',
      body: '先点一条待办选中，再点网格空白处；它就会成为计划块。',
      tab: GuideTab.Plan
    },
    {
      title: '拖动计划块',
      body: '选中块后长按拖动，可以换时间；上下边缘还能自动滚时间轴。',
      tab: GuideTab.Plan
    },
    {
      title: '打开块详情',
      body: '点一下计划块，右侧会滑出详情抽屉；点抽屉外可收起。',
      tab: GuideTab.Plan
    },
    {
      title: '改开始和时长',
      body: '在详情抽屉里用 ± 调开始时间、时长；「完成」保存并收起。',
      tab: GuideTab.Plan
    },
    {
      title: '对半分',
      body: '同一件事想分两段做：在详情里点「对半分」，会拆成相邻两块。',
      tab: GuideTab.Plan
    },
    {
      title: '双指改块时长',
      body: '选中一个块后双指张合，直接拉长或缩短它；每次 5 分钟。',
      tab: GuideTab.Plan
    },
    {
      title: '双指切换视图',
      body: '点空白取消选中后双指捏合：日 → 三日 → 周；反向张开缩回。',
      tab: GuideTab.Plan
    },
    {
      title: '撤销和重做',
      body: '日期栏左上角的 ↶ / ↷ 可以撤销或重做刚才的计划操作；只保留本次运行最近 30 步。',
      tab: GuideTab.Plan
    },
    {
      title: '最后一站：设置',
      body: '背景、标语、待办类型、提醒、备份都在这里；点一行进子页。',
      tab: GuideTab.Settings
    },
    {
      title: '完成演练',
      body: '点下面的「完成演练」：沙箱整份删掉，回到你自己的课表。',
      tab: GuideTab.Settings
    }
  ];
}

export function guideStepCount(): number {
  return guideSteps().length;
}

/** 是不是最后一步 */
export function isLastGuideStep(index: number): boolean {
  return index >= guideStepCount() - 1;
}

/** 下一步（夹在范围内） */
export function nextGuideStep(index: number): number {
  const n: number = index + 1;
  return n > guideStepCount() - 1 ? guideStepCount() - 1 : n;
}

/** 上一步（夹在范围内） */
export function prevGuideStep(index: number): number {
  const n: number = index - 1;
  return n < 0 ? 0 : n;
}

/** 取某一步（越界时退回最后一步），引导条渲染用 */
export function guideStepAt(index: number): GuideStep {
  const steps: GuideStep[] = guideSteps();
  if (index < 0) {
    return steps[0];
  }
  if (index >= steps.length) {
    return steps[steps.length - 1];
  }
  return steps[index];
}

/** 每一步的标签页是否合法（0..3）—— 断言用 */
export function guideTabsValid(): boolean {
  for (const s of guideSteps()) {
    if (s.tab < 0 || s.tab > 3 || Math.round(s.tab) !== s.tab) {
      return false;
    }
  }
  return true;
}

/** 每一步都有标题和正文（断言用） */
export function guideTextsNonEmpty(): boolean {
  for (const s of guideSteps()) {
    if (s.title.trim().length === 0 || s.body.trim().length === 0) {
      return false;
    }
  }
  return true;
}
