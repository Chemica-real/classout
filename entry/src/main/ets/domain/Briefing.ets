import { CourseSession, Todo, TodoCategory } from '../model/Types';
import { minToHHmm } from '../util/DateUtil';

/**
 * 每日简报的正文。
 *
 * 单独放在这里是因为它是纯函数：不碰鸿蒙 API，所以能用 tools/domain-check 离线验证
 * （提醒这种东西在真机上不好反复试，正文写错了只有早上才发现）。
 */
export function buildBriefing(dateStr: string, sessions: CourseSession[], todos: Todo[]): string {
  let text: string = '';
  if (sessions.length === 0) {
    text = '今天没有课。';
  } else {
    const parts: string[] = [];
    for (const s of sessions) {
      const name: string = s.course.shortName.length > 0 ? s.course.shortName : s.course.name;
      const loc: string = s.location.length > 0 ? ` ${s.location}` : '';
      parts.push(`${minToHHmm(s.startMin)} ${name}${loc}`);
    }
    text = `${sessions.length} 节课：${parts.join('；')}`;
  }

  const dueToday: string[] = [];
  for (const t of todos) {
    // 考试不算"今天截止"：它的 ddl 存的是**开始时刻**（用户 2026-10-16：「考试无需显示截止」）。
    // 考试有自己的倒计时与卡片，简报里再报一次"截止"只会误导。
    if (t.category === TodoCategory.Exam) {
      continue;
    }
    if (t.ddl.length >= 10 && t.ddl.substring(0, 10) === dateStr) {
      const hhmm: string = t.ddl.length >= 16 ? t.ddl.substring(11, 16) : '';
      dueToday.push(`${t.title} ${hhmm}`);
    }
  }
  if (dueToday.length > 0) {
    text += ` ｜ 今天截止：${dueToday.join('、')}`;
  }
  return text;
}
