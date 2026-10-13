/**
 * 玻璃态材质（glassmorphism）的统一定义。
 *
 * ⚠️ 玻璃态有个前提：**背后得有"有结构的东西"可模糊**。
 * 纯色底上做 `backgroundBlurStyle` 等于没做（糊纯色还是纯色），
 * 所以必须先用 `PageBackground` 铺一层柔和渐变当底 ——
 * 这层同时也正好是将来「个性化壁纸」的落点：把渐变换成图片，所有玻璃面自动跟着变。
 *
 * 两档材质：
 *   - `glassPanel()`：浮层、弹窗、编辑器、导航栏 —— 厚一点，压住下面的内容
 *   - `glassCard()` ：列表卡片、托盘卡 —— 薄一点，别把后面的东西糊死
 *
 * ⚠️ 刻意**不**给网格/课程块/计划块/输入框上玻璃：
 *   网格是"要读准确时间"的地方，输入框要看清自己打的字，半透明会害了可读性。
 *   材质只用在"容器"上，内容层保持不透明。
 */

/** 卡片玻璃的白色薄纱浓度（叠在模糊之上）——想更"奶白"就调大这个值 */
const TINT_CARD: string = 'rgba(255,255,255,0.44)';
/** 浮层玻璃的薄纱浓度：比卡片浓，保证压在复杂内容上也看得清字 */
const TINT_PANEL: string = 'rgba(255,255,255,0.62)';
/** 玻璃边缘那圈高光细线 */
const EDGE: string = 'rgba(255,255,255,0.72)';
/** 悬浮感来源：柔和的大半径低透明度投影 */
const SHADOW_RADIUS: number = 20;
const SHADOW_COLOR: string = 'rgba(28,45,90,0.13)';
const SHADOW_OFFSET_Y: number = 6;

// ⚠️ 为什么这里只有常量、没有 `@Styles`：
//   ArkTS 的 `@Styles` **不能跨文件 export/import**（实测报
//   `Property 'glassCard' does not exist on type 'ColumnAttribute'`）——
//   它在编译期被当成"该文件里某个组件类型的属性"。
//   所以做法是：**常量集中在这里**（改一处就能整体调浓淡），
//   每个 view 文件里各声明一个**文件内** `@Styles` 引用这些常量。
//   配方只有 5 个属性，复制成本很低；想改配方就 5 个文件一起改（已在 §16 记下）。

/** 卡片玻璃的 5 个属性值，供各文件的 @Styles 引用 */
export const GLASS_CARD_BLUR: BlurStyle = BlurStyle.COMPONENT_REGULAR;
export const GLASS_CARD_TINT: string = TINT_CARD;
export const GLASS_CARD_EDGE: string = EDGE;
export const GLASS_CARD_RADIUS: number = 14;
export const GLASS_CARD_SHADOW: ShadowOptions = {
  radius: SHADOW_RADIUS, color: SHADOW_COLOR, offsetX: 0, offsetY: SHADOW_OFFSET_Y
};

/** 浮层玻璃的 3 个属性值（圆角由调用方给：弹窗 16/18、导航栏 0） */
export const GLASS_PANEL_BLUR: BlurStyle = BlurStyle.COMPONENT_THICK;
export const GLASS_PANEL_TINT: string = TINT_PANEL;
export const GLASS_PANEL_EDGE: string = EDGE;

/**
 * 全 App 的底层背景（玻璃态的"可透物"）。
 *
 * 铺在 `Index` 根 Stack 的最底层；各页面的根容器要把自己的
 * `backgroundColor` 去掉（或设成透明），否则会把这一层挡住、玻璃就白做了。
 */
@Component
export struct PageBackground {
  build() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 160,
        colors: [['#E6EEFF', 0.0], ['#F1EDFF', 0.42], ['#E4F6F1', 1.0]]
      })
  }
}
