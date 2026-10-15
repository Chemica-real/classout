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
      title: '这是你的课表',
      body: '演练里已经放好 4 门演示课。点任意一节课的色块，会弹出「换教室 / 调课 / 停课」——'
        + '随便改成什么样都行，动的只是演练数据。',
      tab: GuideTab.Timetable
    },
    {
      title: '改一节试试',
      body: '在弹出的面板里把「换教室」那一栏改个地点、点「换到这儿」，课表上的地点当场就变了。'
        + '（这就是平时改教室的地方。）',
      tab: GuideTab.Timetable
    },
    {
      title: '待办：打勾完成',
      body: '切到「待办」。演示待办已经在列表里，点最左边的圆圈就把一条标记完成 ——'
        + '它会去最下面的「已完成」区，还能恢复或删除。',
      tab: GuideTab.Todo
    },
    {
      title: '新建一条待办',
      body: '点底部「＋ 新建待办」：写标题、选类型（类型那一排最后的「＋ 新建类型」'
        + '可以加一个自己的类型）、写备注、挑截止时间，最后保存。',
      tab: GuideTab.Todo
    },
    {
      title: '计划：把待办排进时间',
      body: '切到「计划」。底部「待安排」点开，先点一条待办选中，再点网格上的空白处就排上了；'
        + '排好后还能拖动、双指缩放改时长。',
      tab: GuideTab.Plan
    },
    {
      title: '设置',
      body: '最后一站：背景、首页标语、待办类型、不可排时段、计划页时间范围都在这一页。'
        + '想看哪个点哪个，改坏了也不要紧。',
      tab: GuideTab.Settings
    },
    {
      title: '演练结束',
      body: '点下面的「完成演练」：演练数据会整份删掉，回到你自己的课表 ——'
        + '刚才的每一步都是真实操作，只是做在了沙箱里。',
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
