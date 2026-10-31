import { SectionTime } from '../model/Types';

/**
 * 「当前时间」红线在课表网格里的纵坐标（vp）。
 *
 * 用户 2026-10-30 要求：课表和计划页用一根水平红细线标出此刻（随时更新）。
 * 计划页是连续时间轴（1 分钟 = 1vp），直接 `yOf(nowMin)` 就行；
 * 课表网格是**按节次分行**的，行高还可能不同（机动节次更矮），所以要单独换算。
 *
 * 做法：每节内部按时间线性插值；节与节之间的课间空档，在「上一节底边」和
 * 「下一节顶边」之间线性插值（行高本来就紧挨着，所以空档多半是一条水平线）。
 * 这样线是**连续**的，不会在课间断成几截。
 *
 * @param sections 节次时间（按 section 升序，调用方保证）
 * @param heights  与 sections **一一对应**的每节行高（vp）
 * @param minute   当天 0 点起的分钟数
 * @returns 网格内 y；`-1` = 不在第一节课开始到最后一节课结束之间（不该画）
 */
export function timetableNowY(sections: SectionTime[], heights: number[], minute: number): number {
  if (sections.length === 0 || minute < 0) {
    return -1;
  }
  let y: number = 0;
  let prevEndMin: number = sections[0].startMin;
  let prevBottomY: number = 0;
  for (let i = 0; i < sections.length; i++) {
    const st: SectionTime = sections[i];
    const h: number = i < heights.length && heights[i] > 0 ? heights[i] : 0;
    if (minute < st.startMin) {
      // 还没到这一节：若在上一节的结束之后，就是课间空档
      if (i === 0) {
        return -1;
      }
      const gap: number = st.startMin - prevEndMin;
      if (gap <= 0) {
        return y;
      }
      const t: number = (minute - prevEndMin) / gap;
      return prevBottomY + t * (y - prevBottomY);
    }
    if (minute <= st.endMin) {
      const span: number = st.endMin - st.startMin;
      if (span <= 0) {
        return y;
      }
      return y + ((minute - st.startMin) / span) * h;
    }
    prevEndMin = st.endMin;
    prevBottomY = y + h;
    y += h;
  }
  // 最后一节课结束之后
  return -1;
}
