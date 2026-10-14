/**
 * 悬浮浮窗（floating glass bars）的通用几何。
 *
 * 2026-10-14 用户要求：把网页最上面那条（学期/周次/补课/管理课程/今天）、计划页的日期栏、
 * 底部导航栏都做成**悬浮圆角矩形玻璃浮窗**，并且**内容上下滚动时会钻到浮窗下面**。
 *
 * 于是布局从「页头 + 内容 + 导航栏」的**流式**排列改成了：
 *
 * ```
 * Stack
 *  ├ PageBackground            最底层（渐变/照片）
 *  ├ 内容层（铺满整屏）          ← 靠**内容自己的上下 padding** 给浮窗让位
 *  └ 浮窗层（不参与内容布局）
 *      ├ 顶部浮窗栈            ← 页头（+ 课表周条 / 计划页日期栏）
 *      └ 底部浮窗（导航栏）
 * ```
 *
 * ⚠️ **padding 加在"滚动内容"上，不是加在视口上**，这是"能钻到浮窗下面"的关键：
 * 加在视口上内容会停在浮窗外侧、永远钻不进去；加在内容上则第一帧停在浮窗下方，
 * 一往上滑就钻进去了，而滑到底时最后一条也能完整露出来（首尾都摸得到）。
 *
 * ⚠️ **网格类表头（课表周条 / 计划页三日列头）不能用 layoutWeight**：
 * 浮窗有侧边距，按剩余宽度均分的话列宽会比下面的网格窄，越往右偏得越多。
 * 它们的做法是「**满宽内容层 + 左右留边的玻璃背景层**」，内容层沿用与网格
 * 完全一样的 padding/列宽（见 `pages/Index.ets` 的 `WeekFloat`、
 * `view/PlanDayView.ets` 的 `ColHeadFloat`）。
 */

/** 浮窗左右外边距（vp）。网格类表头只把**背景**缩进这么多，内容仍然满宽 */
export const FLOAT_SIDE: number = 10;
/** 浮窗之间的竖直间距（也是浮窗与屏幕/内容区边缘的间距） */
export const FLOAT_GAP: number = 10;
/** 顶部浮窗与内容区顶边的间距 */
export const FLOAT_TOP: number = 8;

/**
 * 各浮窗的**名义高度**（vp）。
 *
 * ⚠️ 它们只用来给内容留出**第一帧**的 padding；真实高度由各浮窗自己的
 * `onAreaChange` 量出来覆盖（`headerBlockH` / `tabbarH` / `topBarsH` …）。
 * 之所以还要留默认值：不设的话第一帧 padding = 0，内容会先顶到屏幕上边、
 * 下一帧再跳下去（能看出来）。改这里之前先想想"量到真值之前长什么样"。
 */
export const H_HEADER: number = 78;
export const H_TABBAR: number = 54;
export const H_WEEKROW: number = 38;
export const H_DAYBAR: number = 46;
export const H_COLHEAD: number = 34;
export const H_ACTIONS: number = 44;
export const H_TITLE: number = 44;
