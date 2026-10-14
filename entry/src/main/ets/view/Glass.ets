import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WallpaperRepo } from '../data/WallpaperRepo';

/**
 * 毛玻璃材质（glassmorphism）的统一定义 —— **深色主题版**。
 *
 * ⚠️ 玻璃态有个前提：**背后得有"有结构的东西"可模糊**。
 * 纯色底上做模糊等于没做（糊纯色还是纯色），所以先用 `PageBackground` 铺一层
 * **深色渐变 + 两个装饰光晕**当底 —— 这层同时也正好是「个性化壁纸」的落点：
 * 把渐变换成图片，所有玻璃面自动跟着变。
 *
 * ## 为什么是深色
 * 文章那套（**白色低 alpha 玻璃 + 白字**）**只在深底上成立**：
 * alpha 0.10–0.20 才是"背景清晰可见"的毛玻璃，0.50 以上就不算毛玻璃了。
 * 浅底上想达到同样的对比度就得把 alpha 加到 0.5 左右，那就退化成"半透明塑料"了。
 * 所以「改深色」和「降 alpha」是同一件事，不能只做一半。
 *
 * ## 三档材质（模糊只留给"大面"）
 *   - `glassPanel()`：页头、导航栏、浮层 —— 有模糊
 *   - `glassSheet()` / `glassShell()`：弹窗、编辑器 —— 有模糊 + 大圆角 + 浮起阴影
 *   - `glassCard()`：列表行、小卡 —— **不模糊**，只靠半透明纯色透气
 *
 * 列表行不模糊是按用户拍定的**性能取舍**：一屏十几张卡各挂一次背景模糊，
 * 真机滚动会掉帧。模糊留给"大面"，小卡退化成"半透明纯色"仍然有玻璃观感。
 *
 * ## ⚠️ 两处硬约束（都已实测/核实，改之前先读）
 * 1. **模糊要用 `backdropBlur(N)`（模糊背后），不能用 `.blur()`（模糊自己）。**
 *    API 18 的 SDK 里 `.blur()` 原文是 *"content blurring effect for the current component"* ——
 *    挂到卡片容器上会把**卡片里的文字一起糊掉**。文章里 `.blur()` 能用的场景
 *    （背景层与内容层分成兄弟节点）我们这里用不到，所以一律 `backdropBlur`。
 * 2. **`@Styles` 不能跨文件 export/import**（实测报
 *    `Property 'glassCard' does not exist on type 'ColumnAttribute'`）——
 *    它在编译期被当成"该文件里某个组件类型的属性"。
 *    所以做法是：**配方常量集中在这个文件**（改浓淡只改这里），
 *    **5 个 view 文件里各声明一个文件内 `@Styles`** 引用这些常量。
 *    改"配方结构"（加一个属性）要 5 个文件一起改，改"浓淡"只改这里。
 *
 * ⚠️ 刻意**不**给网格/课程块/计划块/输入框上玻璃：
 *   网格是"要读准确时间"的地方，输入框要看清自己打的字，半透明会害了可读性。
 *   材质只用在"容器"上，内容层保持不透明。
 */

// ============================ 一、玻璃配方（唯一可调处）============================

/**
 * 模糊半径（vp）。
 *
 * 文章速查：5–15 中等（卡片主体）、16–30 强（主要面板）、31–60 极强（光晕）。
 * 取 20：面板挡得住底下滚动的文字，又不至于把背景的课程色块糊成一片单色。
 * 设备密度约 3x，20vp ≈ 60px —— 正好落在"大于字形（~30px）才读不出字、
 * 小于色块（~180px）才留得下形状"这个区间里（§16.4 的结论）。
 */
export const GLASS_BLUR: number = 20;
/** 浮层/页头/导航栏的薄纱（文章推荐区间 0.10–0.20，取偏厚一档保可读性） */
export const GLASS_TINT_PANEL: string = 'rgba(255,255,255,0.16)';
/** 弹窗/编辑器的薄纱：比面板再厚一点，它要压在复杂内容上 */
export const GLASS_TINT_SHEET: string = 'rgba(255,255,255,0.18)';
/** 列表行/小卡的薄纱（**不模糊**，只靠透明度透气） */
export const GLASS_TINT_ROW: string = 'rgba(255,255,255,0.10)';
/** 玻璃边缘那圈高光细线（文章：1px 亮边） */
export const GLASS_EDGE_STRONG: string = 'rgba(255,255,255,0.25)';
/** 小卡的描边：比大面弱一档，免得满屏白框 */
export const GLASS_EDGE_SOFT: string = 'rgba(255,255,255,0.14)';
/** 大圆角（文章建议值） */
export const GLASS_RADIUS: number = 20;
/** 小卡的柔和投影（深色底上要够黑才看得出"浮起"） */
export const GLASS_SHADOW_ROW: ShadowOptions = {
  radius: 16, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 6
};
/** 弹窗的投影：半径更大、更黑，把窗口从背景里"抬"起来 */
export const GLASS_SHADOW_SHEET: ShadowOptions = {
  radius: 26, color: 'rgba(0,0,0,0.42)', offsetX: 0, offsetY: 10
};

/**
 * ## 悬浮"货架"（计划页的待安排托盘）
 *
 * 用户要求"待安排窗格也做成悬浮的，但要稍微有所不同以产生层次感"。
 * 层次靠**三层不透明度**拉开（和文章里"卡片薄、浮层厚"同一个思路）：
 *   - 内容/网格：完全透明，贴在背景上（最下层）
 *   - **货架**：**压暗**的半透明 + 小一号的圆角 + 收敛的阴影 → 像"凹进去的抽屉"，
 *     托盘里的卡片（0.10 白）压在上面才浮得起来
 *   - 底部导航栏：最亮的薄纱 + 大圆角 + 最大阴影 → 永远是最上面那层"系统 chrome"
 *
 * 三个值刻意与 `GLASS_TINT_ROW` / `GLASS_RADIUS` / `GLASS_SHADOW_SHEET` 都不一样，
 * 就是为了"一眼看出这是两层不同的东西"。
 */
export const GLASS_TINT_SHELF: string = 'rgba(10,14,26,0.42)';
export const GLASS_EDGE_SHELF: string = 'rgba(255,255,255,0.18)';
export const GLASS_RADIUS_SHELF: number = 16;
export const GLASS_SHADOW_SHELF: ShadowOptions = {
  radius: 12, color: 'rgba(0,0,0,0.30)', offsetX: 0, offsetY: 4
};

// ============================ 二、默认背景（深色渐变 + 光晕）============================

/**
 * 默认渐变背景的三个色标（没设自定义背景时用它）。
 * 导出是为了让设置页的"背景预览"用**同一份颜色**，不然两处各写一份迟早不一致。
 */
export const PAGE_GRADIENT_A: string = '#0f0c29';   // 顶部 深蓝黑
export const PAGE_GRADIENT_B: string = '#302b63';   // 中部 深紫蓝
export const PAGE_GRADIENT_C: string = '#24243e';   // 底部 深紫

/**
 * 背景上的两个装饰光晕。
 *
 * 做法用的是掘金那篇的结构：**模糊挂在一个专门做背景、没有内容的节点上**
 * （这里是空 `Column` 加纯色底），所以 `.blur()` 糊的正好是它自己那团颜色，
 * 得到一圈柔和的辉光 —— 这是 `.blur()` 少数用对了的地方。
 * 它们只是为了"背景有结构可透"，不参与任何交互（`HitTestMode.None`）。
 */
export const GLOW_PINK: string = '#ff6fd8';
export const GLOW_PINK_BLUR: number = 80;
export const GLOW_PINK_OPACITY: number = 0.35;
export const GLOW_CYAN: string = '#00d4ff';
export const GLOW_CYAN_BLUR: number = 60;
export const GLOW_CYAN_OPACITY: number = 0.25;

/**
 * 照片当背景时的"可读性薄纱"。
 *
 * ⚠️ 深色主题下这层要**压暗**（原来是 `rgba(255,255,255,0.55)` 提亮）：
 * 白字直接压在照片的亮部会读不出来，垫一层深色之后照片还在、字也读得清。
 *
 * ⚠️ 2026-10-14 用户实测反馈："时间轴的时间看不清" —— 0.48 太淡，
 * 照片亮部（人像的浅色衣服）正好压在时间刻度上，浅灰字直接糊进背景。
 * **提到 0.62**：照片仍然看得清轮廓（"若隐若现"），但网格上的字保住了对比度。
 * 想更"透"就调小（0.45），想更"稳"就调大（0.75）。这个值是**唯一**能同时压住
 * 课表页与计划页两个网格的地方（它们的字都直接压在背景上，没有卡片兜底）。
 */
export const WALLPAPER_VEIL: string = 'rgba(6,8,16,0.62)';

/**
 * 全屏浮层的背板（"管理课程"那类**没有深色遮罩**的浮层用它）。
 *
 * ⚠️ 它的职责是"把背景**糊到看得出形状、读不出字**"，不是"把背景盖没"：
 * 太浓就变成抹掉背景（违背"若隐若现"），太淡则底下的字还能读、看着像渲染故障。
 * 所以它必须**配一层 `backdropBlur(GLASS_BLUR)`** 一起用，见 `pages/Index.ets`。
 * 其余三个 sheet / 两个编辑窗本来就自带 `rgba(12,18,28,0.45)` 深色遮罩，不需要它。
 */
export const SCRIM_COLOR: string = 'rgba(8,10,20,0.42)';

// ============================ 三、背景层组件 ============================

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
          direction: GradientDirection.Bottom,
          colors: [[PAGE_GRADIENT_A, 0.0], [PAGE_GRADIENT_B, 0.5], [PAGE_GRADIENT_C, 1.0]]
        })
      // 两个装饰光晕：让"纯净的深色渐变"有结构可透，玻璃压上去才有东西可糊。
      // 注意它们**在照片之下**：设了自定义背景就看不见（那是刻意的，照片本身就是结构）。
      Column()
        .width(280)
        .aspectRatio(1)
        .borderRadius(140)
        .backgroundColor(GLOW_PINK)
        .blur(GLOW_PINK_BLUR)
        .opacity(GLOW_PINK_OPACITY)
        .position({ top: 60, right: -40 })
        .hitTestBehavior(HitTestMode.None)
      Column()
        .width(200)
        .aspectRatio(1)
        .borderRadius(100)
        .backgroundColor(GLOW_CYAN)
        .blur(GLOW_CYAN_BLUR)
        .opacity(GLOW_CYAN_OPACITY)
        .position({ bottom: 100, left: -30 })
        .hitTestBehavior(HitTestMode.None)
      if (this.pixmap !== undefined) {
        Image(this.pixmap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .draggable(false)
        // 可读性薄纱（照片明暗不可控，正文还压在它上面）—— 深色主题下是"压暗"
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
