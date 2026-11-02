/**
 * 应用内更新日志。
 *
 * 用户 2026-11-01：「更新日志（每次更新时显示比用户的上一个版本更新的内容）」。
 * 这里只放**面向用户**的短条目；版本号与 versionCode 一起写，比较用 code，
 * 避免字符串比较 1.10 < 1.9 这类坑。
 */

export interface ChangelogEntry {
  code: number;
  version: string;
  items: string[];
}

export function changelogEntries(): ChangelogEntry[] {
  return [
    {
      code: 1007000,
      version: '1.7.0',
      items: [
        '日历不再生成「即将截止」事件。',
        '待办日程标题前加课程简称，备注第一行是截止时间。',
        '考试计划块改为红色警告边框。',
        '计划块备注可点按复制；点详情抽屉外可收起。',
        '待办完成时，计划页里它的所有分块一起完成。'
      ]
    },
    {
      code: 1007001,
      version: '1.7.1',
      items: [
        '待办可以按截止时间或标题排序，选择会记住。',
        '待确认、考试、今天、逾期、以后都能折叠。'
      ]
    },
    {
      code: 1007002,
      version: '1.7.2',
      items: [
        '待办支持左滑删除，删除前可确认。',
        '删除时播放碎裂动画；确认开关在设置里。'
      ]
    },
    {
      code: 1007003,
      version: '1.7.3',
      items: [
        '滚动到列表顶部/底部时有轻震动反馈。',
        '新手引导拆成 18 个短步骤，每步只做一件事。',
        '更新后首次启动会显示本页更新日志。'
      ]
    },
    {
      code: 1008000,
      version: '1.8.0',
      items: [
        '计划页支持撤销/重做：日期栏左上角 ↶ / ↷，本次运行内最多 30 步。',
        '外部改动、换学期、恢复备份、进出演练会清空计划历史，避免旧快照覆盖新数据。',
        '删除待办的确认文案只保留“删除后不可恢复”。'
      ]
    }
  ];
}

/**
 * 取 `(lastCode, currentCode]` 之间的条目。
 * 首次运行（lastCode <= 0）时取当前版本及之前的全部近期条目，
 * 这样从旧版本升上来、第一次出现更新日志的用户也能看到完整变化。
 */
export function changelogBetween(lastCode: number, currentCode: number): ChangelogEntry[] {
  const out: ChangelogEntry[] = [];
  for (const e of changelogEntries()) {
    if (e.code > currentCode) {
      continue;
    }
    if (lastCode > 0 && e.code <= lastCode) {
      continue;
    }
    out.push(e);
  }
  out.sort((a: ChangelogEntry, b: ChangelogEntry): number => a.code - b.code);
  return out;
}
