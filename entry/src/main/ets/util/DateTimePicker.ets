import { UIContext } from '@kit.ArkUI';
import { formatDateTime, parseDateTime } from './DateUtil';

/**
 * 用**鸿蒙自己的**日期选择器 + 时间选择器挑一个「日期 + 时刻」。
 *
 * 为什么不用 `TextInput` 让用户手打：手打要自己解析、要容错、手机上还费劲；
 * 系统选择器是滚轮、点两下就完事，且**分钟不受任何限制**（用户明确要求：
 * 截止时间不必是 5 分钟的整数倍 —— 5 分钟那条规矩只属于"预计时长"）。
 *
 * 两步是**串起来**的（先日期、定了日期再弹时间），理由：
 * - 一个弹窗里塞不下日期+时间两排滚轮时体验很差，系统也没给这种组合弹窗；
 * - 只有两步都走完才回调 —— 在日期那步取消就整个不动，不会出现
 *   "日期改了、时刻还是旧的"这种半截结果。
 *
 * `initial` 是 'YYYY-MM-DD HH:mm'；空串 = 还没有截止时间（这时种子取"此刻"，
 * 时间那一步默认 23:59，和界面上的快捷胶囊一致）。
 */
export function pickDateTime(ui: UIContext, initial: string,
  onPicked: (value: string) => void): void {
  const hasTime: boolean = initial.length >= 16;
  const seed: Date = parseDateTime(initial);
  // ⚠️ **日期那一步要喂"当天正午"，不能喂带真实时刻的 Date。**
  //   真机实测（2026-10-14）：存的是 `2026-10-14 21:59`，弹出来的日期选择器却高亮在
  //   **10月15日**；直接点「确定」不改任何东西，截止时间就被悄悄推后了一天。
  //   这是 ArkUI DatePickerDialog 对 `selected` 的时区处理造成的偏移（小时数一加就跨天）。
  //   喂正午之后，无论它按 ±12 小时里的哪种口径解释，都落在**同一天**上。
  //   时刻那一步仍用真实时刻（实测 TimePicker 显示 21:59 正确，不受这个偏移影响）。
  const daySeed: Date = new Date(seed.getFullYear(), seed.getMonth(), seed.getDate(), 12, 0);
  ui.showDatePickerDialog({
    selected: daySeed,
    onDateAccept: (day: Date): void => {
      const h: number = hasTime ? seed.getHours() : 23;
      const m: number = hasTime ? seed.getMinutes() : 59;
      ui.showTimePickerDialog({
        selected: new Date(day.getFullYear(), day.getMonth(), day.getDate(), h, m),
        useMilitaryTime: true,
        onAccept: (v: TimePickerResult): void => {
          const picked: Date = new Date(day.getFullYear(), day.getMonth(), day.getDate(),
            v.hour === undefined ? h : v.hour,
            v.minute === undefined ? m : v.minute);
          onPicked(formatDateTime(picked));
        }
      });
    }
  });
}
