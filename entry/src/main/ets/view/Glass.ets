import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WallpaperRepo } from '../data/WallpaperRepo';

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

/**
 * 玻璃面的"薄纱"不是纯色，而是**上亮下暗的渐变**。
 *
 * 依据（用户给的玻璃态说明里的第 ③ 条）："边框**和渐变**增强玻璃态元素的立体感和空间深度"。
 * 纯色填充 + 描边只能得到一块"扁平的半透明塑料"；加一层竖向渐变之后，
 * 顶部亮、底部略透，看起来才像"光从上方打在一块厚玻璃上"。
 *
 * 两档还刻意做出**不透明度分层**（说明里的设计技巧之一：层叠使用可增强层次感）：
 *   - 卡片是"平铺"的，薄一点，让背景更明显（弱前景 / 强背景）
 *   - 浮层是"抬起"的，厚一点，保证压在复杂内容上字也看得清（强前景）
 */
const TINT_CARD_TOP: string = 'rgba(255,255,255,0.52)';
const TINT_CARD_BOTTOM: string = 'rgba(255,255,255,0.28)';
const TINT_PANEL_TOP: string = 'rgba(255,255,255,0.74)';
const TINT_PANEL_BOTTOM: string = 'rgba(255,255,255,0.48)';
/** 玻璃边缘那圈高光细线（说明第 ③ 条的"描边"） */
const EDGE: string = 'rgba(255,255,255,0.80)';
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

/** 卡片玻璃的属性值，供各文件的 @Styles 引用 */
export const GLASS_CARD_BLUR: BlurStyle = BlurStyle.COMPONENT_REGULAR;
export const GLASS_CARD_TOP: string = TINT_CARD_TOP;
export const GLASS_CARD_BOTTOM: string = TINT_CARD_BOTTOM;
export const GLASS_CARD_EDGE: string = EDGE;
export const GLASS_CARD_RADIUS: number = 14;
export const GLASS_CARD_SHADOW: ShadowOptions = {
  radius: SHADOW_RADIUS, color: SHADOW_COLOR, offsetX: 0, offsetY: SHADOW_OFFSET_Y
};

/** 浮层玻璃的属性值（圆角由调用方给：弹窗 16/18、导航栏 0） */
export const GLASS_PANEL_BLUR: BlurStyle = BlurStyle.COMPONENT_THICK;
export const GLASS_PANEL_TOP: string = TINT_PANEL_TOP;
export const GLASS_PANEL_BOTTOM: string = TINT_PANEL_BOTTOM;
export const GLASS_PANEL_EDGE: string = EDGE;

/**
 * 照片当背景时的"可读性薄纱"。
 *
 * 照片的明暗不可控，正文/刻度直接压在照片上会读不清；
 * 垫一层半透明白之后，照片还在、字也读得清。
 * 想更"透"就调小（0.35），想更"稳"就调大（0.7）。
 */
export const WALLPAPER_VEIL: string = 'rgba(255,255,255,0.55)';

/**
 * 默认渐变背景的三个色标（没设自定义背景时用它）。
 * 导出是为了让设置页的"背景预览"用**同一份颜色**，不然两处各写一份迟早不一致。
 */
export const PAGE_GRADIENT_A: string = '#E6EEFF';
export const PAGE_GRADIENT_B: string = '#F1EDFF';
export const PAGE_GRADIENT_C: string = '#E4F6F1';

/**
 * 全 App 的底层背景（玻璃态的"可透物"）。
 *
 * 铺在 `Index` 根 Stack 的最底层；各页面的根容器要把自己的
 * `backgroundColor` 去掉（或设成透明），否则会把这一层挡住、玻璃就白做了。
 *
 * **自定义背景优先，没有才用渐变**（用户要求）：
 *   `wallpaper` 里存的是沙盒里的图片路径，由设置页写入、`Index.init()` 从 kv 冷启动恢复。
 *   用 `@StorageLink` 而不是一路传回调：设置页和背景层隔了好几层，走 AppStorage 最干净，
 *   而且换图之后**所有**玻璃面自动跟着变（它们本来就是透的）。
 */
@Component
export struct PageBackground {
  @StorageLink('wallpaper') @Watch('onWallpaperChanged') wallpaper: string = '';
  /** 解码后的背景图；undefined = 还没解出来/解码失败 → 显示渐变 */
  @State pixmap: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.refreshWallpaper();
  }

  onWallpaperChanged(): void {
    this.refreshWallpaper();
  }

  private refreshWallpaper(): void {
    const p: string = this.wallpaper;
    if (p.length === 0) {
      this.pixmap = undefined;   // 回到渐变
      return;
    }
    this.decodeAsync(p).catch((e: Object): void => {
      hilog.warn(0x0000, 'ClassOUT', 'wallpaper decode async failed: %{public}s',
        JSON.stringify(e));
    });
  }

  private async decodeAsync(p: string): Promise<void> {
    const d: display.Display = display.getDefaultDisplaySync();
    const pm: image.PixelMap | undefined = await WallpaperRepo.decode(p, d.width, d.height);
    // 解码期间用户又换了一张 → 丢弃这次结果，否则旧图会盖住新图
    if (this.wallpaper !== p) {
      return;
    }
    this.pixmap = pm;   // 失败时是 undefined，自动退回渐变
  }

  build() {
    Stack() {
      // 渐变永远在底层：解码期间/解码失败时都有东西垫着，不会闪黑
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [[PAGE_GRADIENT_A, 0.0], [PAGE_GRADIENT_B, 0.42], [PAGE_GRADIENT_C, 1.0]]
        })
      if (this.pixmap !== undefined) {
        Image(this.pixmap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .draggable(false)
        // 可读性薄纱（照片明暗不可控，正文还压在它上面）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WALLPAPER_VEIL)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
  }
}
