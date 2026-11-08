// 更新日志 —— 与鸿蒙端 domain/Changelog.ets 的条目保持同一条时间线。
// 只列用户能感知的变化；维护时两条线一起改。

class ChangelogEntry {
  final String version;
  final List<String> items;

  const ChangelogEntry(this.version, this.items);
}

const List<ChangelogEntry> changelogEntries = [
  ChangelogEntry('1.10.0', [
    '待办页在「以后」和「已完成」之间新增虚拟课程文件夹：课程名 + 课程色 + 已完成/总数，点进去是完整课时页。',
    '课时页可逐讲改名、改这一讲时长、删除这一讲；完成的课时原地灰掉。',
    '课时打勾会同步计划块并生成待办；没排课的用当前时间 + 时长生成，不补计划块。',
    '全部课时完成的课程行显示「✓ 已完成」；已完成的课仍可点进去取消。',
    '虚拟课程页面、课时卡统一为待办页的玻璃卡片；课时页背景使用全局壁纸。',
  ]),
  ChangelogEntry('1.9.2', [
    '修正待安排栏的点击命中：点按钮不会再被外层空白点击吞掉。',
  ]),
  ChangelogEntry('1.9.1', [
    '修复待安排栏空白区域点击穿透到下面的课表。',
  ]),
  ChangelogEntry('1.9.0', [
    '计划页支持虚拟课程块、选中拖动、双指缩放和计划页直接完成。',
    '新增提醒与沙粒删除动画。',
  ]),
];
