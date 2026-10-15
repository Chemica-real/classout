/**
 * 设置页（导航栏最后一条）
 *
 * 用户要求：「把各种设置单独拿出来放在导航栏中最后一条，单独设置一个设置界面」。
 *
 * 设计要点：**这个组件自带 state、自己读库写库**，不靠父组件把一堆 @Prop 灌进来。
 * 原因是本项目已经踩过的 ArkTS 坑：`ForEach` / `if` 复用的子组件在 props 不变时
 * 不会重新渲染（HANDOFF §12.4 第 4 条，「待办改属性不刷新」就是这个）。
 * 自带 state 的页面不存在这个问题 —— 它自己就是数据的 owner。
 *
 * ⚠️ 从 `CourseManager` 搬过来的东西**必须同时从那边删掉**，否则同一个设置有两处入口。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { RestWindow, TodoCategory } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { TodoRepo } from '../data/TodoRepo';
import { ReminderSettings, loadReminderSettings, saveReminderSettings } from '../domain/ReminderScheduler';
import { Validation, normalizeRestEnd, validateRestWindow } from '../domain/Validate';
import { WEEKDAY_CN, hhmmToMin, minToHHmm } from '../util/DateUtil';
import { ChipButton } from './ChipButton';
import { image } from '@kit.ImageKit';
import { display } from '@kit.ArkUI';
import { WallpaperGeometry, WALLPAPER_MAX_ZOOM, WALLPAPER_MIN_ZOOM, clampFocus,
  formatWallpaperFocus, parseWallpaperFocus, wallpaperGeometry } from '../domain/Wallpaper';
import { WallpaperRepo } from '../data/WallpaperRepo';
import { PAGE_GRADIENT_A, PAGE_GRADIENT_B, PAGE_GRADIENT_C, WALLPAPER_VEIL } from './Glass';
import { GLASS_BLUR, GLASS_EDGE_STRONG, GLASS_RADIUS, GLASS_SHADOW_ROW, GLASS_SHADOW_SHEET,
  GLASS_TINT_PANEL, GLASS_TINT_SHEET } from './Glass';
import { FLOAT_GAP, FLOAT_SIDE, FLOAT_TOP, H_TITLE } from './Float';
import { persistMotionSetting } from './Motion';
import { pickTime } from '../util/DateTimePicker';
import { MOTTO_DEFAULT, MOTTO_MAX_UNITS, clampMottoUnits, cleanMotto,
  loadMotto, mottoUnits, saveCustomCategories, saveMotto, savePlanWindow } from '../data/Prefs';
import { DEFAULT_WINDOW, TimeWindow, WINDOW_MAX_END, WINDOW_MIN_SPAN, WINDOW_SNAP_MIN } from '../domain/PlanMath';
import { CATEGORY_MAX_COUNT, CATEGORY_NAME_MAX, CategoryOption, CategoryVerdict,
  addCustomCategory, builtinCategoryOptions, parseCustomCategories, removeCustomCategory,
  validateCategoryName } from '../domain/Categories';

// 文件内 @Styles（见 Glass.ets 顶部注释：@Styles 不能跨文件 export）
// 深色版。设置页的卡片按用户拍定算"大面" → 保留模糊（`glassPanelCard`），
// 它不是列表行那种"一屏十几张"的密度，多几次背景模糊不影响滚动。
@Styles
function glassPanelCard() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_PANEL)
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
  .shadow(GLASS_SHADOW_ROW)
}

@Styles
function glassPanel() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_PANEL)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
}

/** 浮窗（页头/导航栏/日期栏这类"大面"）：模糊 + 大圆角 + 浮起阴影 */
@Styles
function glassSheet() {
  .backdropBlur(GLASS_BLUR)
  .backgroundColor(GLASS_TINT_SHEET)
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: GLASS_EDGE_STRONG })
  .shadow(GLASS_SHADOW_SHEET)
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 每日简报时间的可选档位（分钟） */
const BRIEF_CHOICES: number[] = [390, 420, 450, 480, 540, 720];
/** 上课提前量可选档位（分钟） */
const LEAD_CHOICES: number[] = [5, 10, 15, 20, 30, 45];

@Component
export struct SettingsPage {
  @Prop semesterId: number;
  /** 上方悬浮浮窗占掉的高度（设置页没有课表那套页头，Index 传 0） */
  @Prop topInset: number = 0;
  /** 下方悬浮浮窗（导航栏）占掉的高度，由 Index 量好传进来 */
  @Prop bottomInset: number = 0;
  /**
   * 页面内部开着全屏浮层（背景调整界面）时通知 Index，让它把悬浮浮窗层改画到内容层之下
   * —— 和两个编辑窗同一套路（见 Index.pageModalOpen 的注释）。
   */
  onModalChange: (open: boolean) => void = (): void => {};
  /** 点「开始演练」→ 由 Index 建沙箱库、切库、挂引导条（见 data/GuideRepo） */
  onStartGuide: () => void = (): void => {};
  /** 本页标题栏浮窗量出来的高度 */
  @State titleH: number = H_TITLE;

  @State remSettings: ReminderSettings = { briefEnabled: true, briefMin: 450, classLeadMin: 15 };
  @State restWindows: RestWindow[] = [];
  @State newRestLabel: string = '';
  @State newRestStart: string = '12:00';
  @State newRestEnd: string = '13:00';
  @State newRestWeekday: number = 0;
  /** 正在等二次确认的删除（'rest-7' 这种）。'' = 没有 */
  @State pendingDeleteKey: string = '';
  @State toast: string = '';
  @State loading: boolean = true;
  /** 自定义背景在沙盒里的路径；'' = 用默认渐变（见 view/Glass.ets） */
  @StorageLink('wallpaper') @Watch('onWallpaperChanged') wallpaper: string = '';
  /** 设置页里的背景缩略图 */
  @State wallPreview: image.PixelMap | undefined = undefined;
  /** 背景的显示位置/缩放：'fx,fy,zoom'（归一化，见 domain/Wallpaper） */
  @StorageLink('wallpaperFocus') wallFocus: string = '0,0,1';
  /**
   * 「调整背景」全屏界面开着吗。
   * `@Watch` 是必须的：开的时候要通知 Index 把浮窗层挪到内容层之下（同 TodoInbox）
   */
  @State @Watch('onAdjustChanged') adjusting: boolean = false;
  @State adjPixmap: image.PixelMap | undefined = undefined;
  @State adjImgW: number = 0;
  @State adjImgH: number = 0;
  @State adjBoxW: number = 0;
  @State adjBoxH: number = 0;
  @State adjFx: number = 0;
  @State adjFy: number = 0;
  @State adjZoom: number = 1;
  /** 拖拽/双指开始时的基准值（手势给的是累计位移） */
  private dragFx0: number = 0;
  private dragFy0: number = 0;
  private pinchZoom0: number = 1;
  /** toast 自动消失的定时器（-1 = 没在计时） */
  private toastTimer: number = -1;
  /**
   * 动画总开关（用户要求"可在设置中一次性关闭"）。
   * ⚠️ `@StorageLink` 的键名必须写字面量 —— 详情见 view/Motion.ets。
   */
  @StorageLink('motionOn') motionOn: boolean = true;
  /** 首页标语的就地编辑副本（保存前不动 AppStorage，免得打字时就改到加载页） */
  @State mottoDraft: string = MOTTO_DEFAULT;
  /**
   * 已经保存的标语（`Prefs.saveMotto` 写的就是这个键）。
   *
   * ⚠️ 为什么需要它：设置页是**切标签时销毁、切回来重建**的组件，而 `mottoDraft` 每次
   * 都会重置成默认值 —— 于是「首页标语改了之后在设置页不显示」（用户实测报的 bug）：
   * 保存是成功的，但再进设置页看到的是 `离线课表 · 待办 · 计划`。
   * 挂上这个 StorageLink，重建时就能把**存过的那份**读回输入框。
   */
  @StorageLink('bootMotto') savedMotto: string = MOTTO_DEFAULT;

  /**
   * 计划页时间范围（上下限）。键名必须写字面量（见 Prefs.PLAN_START_KEY 的注释）。
   * 设置页直接写 AppStorage + kv，计划页用同名 `@StorageLink` 订阅，回计划页立刻生效。
   */
  @StorageLink('planStartMin') winStart: number = DEFAULT_WINDOW.startMin;
  @StorageLink('planEndMin') winEnd: number = DEFAULT_WINDOW.endMin;

  /**
   * 自定义待办类型（`'\n'` 分隔）。和待办编辑窗里的「＋新建类型」共用同一份 ——
   * 在待办卡片上新建的类型，回到设置页就能看到、也能删。
   */
  @StorageLink('todoCategories') catRaw: string = '';
  @State catDraft: string = '';
  @State catError: string = '';
  /** 正在等二次确认删除的自定义类型（'' = 没有） */
  @State catPendingDelete: string = '';
  /** 那个类型下有多少条待办（点「删」时查出来，写进确认文案） */
  @State catPendingCount: number = 0;

  aboutToAppear(): void {
    // 回显已保存的标语（见上面 `savedMotto` 的注释）
    this.mottoDraft = this.savedMotto;
    this.refreshPreview();
    this.load();
  }

  private context(): common.UIAbilityContext {
    // 先用 EntryAbility 存好的那份；只有极端情况才回退到已废弃的 getContext()
    const stored: common.UIAbilityContext | undefined = storedAbilityContext();
    if (stored !== undefined) {
      return stored;
    }
    return getContext(this) as common.UIAbilityContext;
  }

  private load(): void {
    this.reload().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'settings load failed: %{public}s', JSON.stringify(e));
      this.loading = false;
    });
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    this.remSettings = await loadReminderSettings(ctx);
    this.restWindows = await TimetableRepo.listRestWindows(ctx);
    this.loading = false;
  }

  /** 弹一条会自动消失的提示（不占布局，避免整页上下跳） */
  aboutToDisappear(): void {
    // 组件销毁（切标签）时浮层也跟着没了，别把"有浮层"的状态留给 Index
    this.onModalChange(false);
  }

  private onAdjustChanged(): void {
    this.onModalChange(this.adjusting);
  }

  /** 打开「调整背景」：把当前的位置/缩放读出来当起点，并解一张预览图 */
  private openAdjust(): void {
    const p: string = this.wallpaper;
    if (p.length === 0) {
      return;
    }
    const cur: number[] = parseWallpaperFocus(this.wallFocus);
    this.adjFx = cur[0];
    this.adjFy = cur[1];
    this.adjZoom = cur[2];
    this.adjusting = true;
    this.loadAdjustPreview(p).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'load adjust preview failed: %{public}s', JSON.stringify(e));
    });
  }

  private async loadAdjustPreview(p: string): Promise<void> {
    const d: display.Display = display.getDefaultDisplaySync();
    const pm: image.PixelMap | undefined = await WallpaperRepo.decode(p, d.width, d.height);
    if (this.wallpaper !== p) {
      return;   // 期间又换了图 → 丢弃
    }
    if (pm === undefined) {
      this.adjusting = false;
      this.showToast('这张背景图读不出来了，请重新选一张');
      return;
    }
    const info: image.ImageInfo = pm.getImageInfoSync();
    this.adjImgW = info.size.width;
    this.adjImgH = info.size.height;
    this.adjPixmap = pm;
  }

  /** 预览用的几何：和 PageBackground 用同一个纯函数 → 所见即所得 */
  private adjGeo(): WallpaperGeometry {
    return wallpaperGeometry(this.adjImgW, this.adjImgH, this.adjBoxW, this.adjBoxH,
      this.adjZoom, this.adjFx, this.adjFy);
  }

  /** 拖拽预览：把手指位移换算成归一化焦点（除以该方向的可动余量） */
  private dragAdjust(dxVp: number, dyVp: number): void {
    const g: WallpaperGeometry = this.adjGeo();
    const nx: number = g.maxDx > 0 ? this.dragFx0 + dxVp / g.maxDx : this.dragFx0;
    const ny: number = g.maxDy > 0 ? this.dragFy0 + dyVp / g.maxDy : this.dragFy0;
    const v: number[] = clampFocus(nx, ny, this.adjZoom);
    this.adjFx = v[0];
    this.adjFy = v[1];
  }

  private cancelAdjust(): void {
    this.adjusting = false;
    this.adjPixmap = undefined;
  }

  private saveAdjust(): void {
    const text: string = formatWallpaperFocus(this.adjFx, this.adjFy, this.adjZoom);
    this.persistFocus(text);
    this.adjusting = false;
    this.adjPixmap = undefined;
    this.showToast('背景位置已保存（所有页面立刻生效）');
  }

  private resetAdjust(): void {
    this.adjFx = 0;
    this.adjFy = 0;
    this.adjZoom = 1;
  }

  private persistFocus(text: string): void {
    const ctx: common.UIAbilityContext = this.context();
    this.wallFocus = text;
    AppStorage.setOrCreate('wallpaperFocus', text);
    WallpaperRepo.saveFocus(ctx, text).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save wallpaper focus failed: %{public}s', JSON.stringify(e));
    });
  }

  private showToast(text: string): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    this.toast = text;
    if (text.length === 0) {
      return;
    }
    this.toastTimer = setTimeout((): void => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2200);
  }

  // ---------------- 背景（玻璃态的"可透物"） ----------------

  /**
   * 冷启动时由 `Index.init()` 从 kv 写进 AppStorage；这里选完图也写同一个键。
   * 用 @StorageLink 是为了让 `PageBackground` 那一层**立刻**跟着换 ——
   * 两个组件隔着好几层，走 AppStorage 比一路传回调干净。
   */
  onWallpaperChanged(): void {
    this.refreshPreview();
  }

  private refreshPreview(): void {
    const p: string = this.wallpaper;
    if (p.length === 0) {
      this.wallPreview = undefined;
      return;
    }
    this.decodePreview(p).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'preview decode failed: %{public}s', JSON.stringify(e));
    });
  }

  private async decodePreview(p: string): Promise<void> {
    const pm: image.PixelMap | undefined = await WallpaperRepo.decode(p, 400, 200);
    // 期间又换了一张 → 丢弃这次结果
    if (this.wallpaper !== p) {
      return;
    }
    this.wallPreview = pm;
  }

  private pickWallpaper(): void {
    this.doPickWallpaper().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'pick wallpaper failed: %{public}s', JSON.stringify(e));
      this.showToast('选图失败，用默认渐变');
    });
  }

  private async doPickWallpaper(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    const path: string = await WallpaperRepo.pick(ctx);
    if (path.length === 0) {
      return;   // 用户取消
    }
    AppStorage.setOrCreate('wallpaper', path);
    this.showToast('背景已换（所有玻璃面跟着变）');
  }

  private clearWallpaper(): void {
    this.doClearWallpaper().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'clear wallpaper failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doClearWallpaper(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await WallpaperRepo.clear(ctx);
    AppStorage.setOrCreate('wallpaper', '');
    this.showToast('已恢复默认渐变背景');
  }

  // ---------------- 提醒设置 ----------------

  private saveRem(): void {
    this.doSaveRem().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save reminder settings failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doSaveRem(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await saveReminderSettings(ctx, this.remSettings);
    // 提醒改动要等下次启动重排才生效（启动时整批重排，见 ReminderScheduler）
    this.showToast('提醒设置已保存（下次启动 App 时重排生效）');
  }

  // ---------------- 休息时段（不可排） ----------------

  private addRest(): void {
    this.doAddRest().catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'add rest window failed: %{public}s', JSON.stringify(e));
    });
  }

  private async doAddRest(): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    if (this.newRestStart.length !== 5 || this.newRestEnd.length !== 5) {
      this.showToast('请先选好开始和结束时间');
      return;
    }
    const label: string = this.newRestLabel.trim().length > 0 ? this.newRestLabel.trim() : '休息';
    const draft: RestWindow = {
      id: 0,
      weekday: this.newRestWeekday,
      startMin: hhmmToMin(this.newRestStart),
      endMin: hhmmToMin(this.newRestEnd),
      label: label
    };
    // 校验走 domain/Validate（纯函数，有离线断言）：起止顺序、范围、HH:mm 格式
    const verdict: Validation = validateRestWindow(draft);
    if (!verdict.ok) {
      this.showToast(verdict.message);
      return;
    }
    await TimetableRepo.insertRestWindow(ctx, draft);
    this.newRestLabel = '';
    this.showToast('已添加不可排时段');
    await this.reload();
  }

  private deleteRest(w: RestWindow): void {
    this.doDeleteRest(w).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'delete rest window failed: %{public}s', JSON.stringify(e));
    });
  }

  /**
   * 选开始 / 结束时刻：弹**鸿蒙自己的时间滚轮**（用户 2026-10-15：「不可排时段添加时这样
   * 强制要求格式的不符合正常人使用规律，改成鸿蒙自带的时间控件」）。
   *
   * ⚠️ 系统滚轮的"时"只到 23，而默认时段里有「睡觉 23:30–24:00」。
   * 所以**结束选成 00:00 且开始不是 0 时，按"到午夜"理解成 24:00** ——
   * 不这样处理，用户就再也设不出到午夜的时段了（00:00 会被判成"结束早于开始"）。
   */
  private pickRestTime(isStart: boolean): void {
    const cur: string = isStart ? this.newRestStart : this.newRestEnd;
    pickTime(this.getUIContext(), cur, (v: string): void => {
      if (isStart) {
        this.newRestStart = v;
        return;
      }
      // 结束：把滚轮选到的 00:00 归位成 24:00（纯函数 + 断言，见 domain/Validate）
      const end: number = normalizeRestEnd(hhmmToMin(v), hhmmToMin(this.newRestStart));
      this.newRestEnd = minToHHmm(end);
    });
  }

  /**
   * 不可排时段的时刻行：标签 + 当前值 + 「选择…」。
   *
   * ⚠️ 显示值必须**直接读 `this.newRestStart/newRestEnd`**，不能当 `@Builder` 参数传进来 ——
   *    参数按值传入、首次渲染后固化（HANDOFF §6.4），选完时间界面不会跟着变。
   *    `isStart` 是静态的（永远不变），所以它当参数没问题。
   */
  @Builder
  RestTimeRow(label: string, isStart: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#94A0B5')
        .width(48)
      Text(isStart ? this.newRestStart : this.newRestEnd)
        .fontSize(15)
        .fontColor('#F2F5FA')
        .layoutWeight(1)
      Button('选择…')
        .backgroundColor('rgba(255,255,255,0.14)')
        .fontColor('#7FA8FF')
        .fontSize(12)
        .height(32)
        .onClick((): void => this.pickRestTime(isStart))
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  private async doDeleteRest(w: RestWindow): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    await TimetableRepo.deleteRestWindow(ctx, w.id);
    this.pendingDeleteKey = '';
    this.showToast('已删除该不可排时段');
    await this.reload();
  }

  private restWeekdayText(w: RestWindow): string {
    return w.weekday === 0 ? '每天' : `周${WEEKDAY_CN[w.weekday - 1]}`;
  }

  private deleteKey(id: number): string {
    return `rest-${id}`;
  }

  // ---------------- UI ----------------

  @Builder
  SectionTitle(text: string, hint: string) {
    Column() {
      Text(text)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2F5FA')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor('#94A0B5')
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  @Builder
  FieldLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#94A0B5')
      .width('100%')
      .margin({ top: 12, bottom: 4 })
  }

  /**
   * 首页标语卡片：改 ClassOUT 字标下面那一行（用户要求，带字数限制）。
   *
   * 三个细节：
   *  - `maxLength(MOTTO_MAX)` **和保存时的截断**都做 —— 光靠输入框限制挡不住粘贴；
   *  - 右下角显示 `n/MOTTO_MAX`，让人知道还能写多少；
   *  - 留空 = 恢复默认标语（见 data/Prefs.ets 的第 2 条约定）。
   */
  @Builder
  MottoCard() {
    Column() {
      this.SectionTitle('首页标语',
        `写在 ClassOUT 下面那一行。上限按显示宽度算：${MOTTO_MAX_UNITS} 宽度 = 16 个汉字或 32 个英文字母；留空恢复默认。`)

      TextInput({ text: this.mottoDraft, placeholder: MOTTO_DEFAULT })
        .fontColor('#F2F5FA')
        .placeholderColor('#8B97AC')
        .caretColor('#7FA8FF')
        // ⚠️ 不用 `maxLength`：它按**字符数**卡，16 个汉字同样放得下，
        // 但"32 个英文字母"会被它误伤。改成按显示宽度实时截断（见 data/Prefs.ets）。
        .onChange((v: string): void => {
          this.mottoDraft = clampMottoUnits(v);
        })
        .onSubmit((): void => this.doSaveMotto())

      Row() {
        Text(`${mottoUnits(this.mottoDraft)}/${MOTTO_MAX_UNITS}`)
          .fontSize(11)
          .fontColor(mottoUnits(this.mottoDraft) >= MOTTO_MAX_UNITS ? '#E8B25C' : '#8B97AC')
          .layoutWeight(1)
        Button('恢复默认')
          .backgroundColor('rgba(255,255,255,0.10)')
          .fontColor('#C3CDDE')
          .fontSize(12)
          .height(30)
          .margin({ right: 8 })
          .onClick((): void => {
            this.mottoDraft = MOTTO_DEFAULT;
            this.doSaveMotto();
          })
        Button('保存')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .fontSize(12)
          .height(30)
          .onClick((): void => this.doSaveMotto())
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .margin({ bottom: 12 })
  }

  private doSaveMotto(): void {
    saveMotto(this.context(), this.mottoDraft).then((t: string): void => {
      this.mottoDraft = t;
      this.showToast('首页标语已保存');
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'save motto failed: %{public}s', JSON.stringify(e));
      this.showToast('保存失败');
    });
  }

  // ---------------- 计划页时间范围（上下限） ----------------

  /**
   * 上/下边界各走一格（`delta = ±WINDOW_SNAP_MIN`）。
   *
   * 夹紧交给 `normalizeWindow`：它保证 [0,24:00] 内、至少 1 小时、且吸附到半小时。
   * 所以"上边界推到下边界头上"时会被顶住，不会出现反着的窗。
   */
  private stepPlanWindow(isStart: boolean, delta: number): void {
    const w: TimeWindow = isStart
      ? { startMin: this.winStart + delta, endMin: this.winEnd }
      : { startMin: this.winStart, endMin: this.winEnd + delta };
    this.applyPlanWindow(w);
  }

  private resetPlanWindow(): void {
    this.applyPlanWindow(DEFAULT_WINDOW);
  }

  private applyPlanWindow(w: TimeWindow): void {
    savePlanWindow(this.context(), w).then((n: TimeWindow): void => {
      this.winStart = n.startMin;
      this.winEnd = n.endMin;
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'save plan window failed: %{public}s', JSON.stringify(e));
      this.showToast('保存失败');
    });
  }

  private windowSpanText(): string {
    const total: number = this.winEnd - this.winStart;
    const h: number = Math.floor(total / 60);
    const m: number = total % 60;
    return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
  }

  // ---------------- 待办类型（自定义 category） ----------------

  /**
   * 自定义待办类型的管理（用户 2026-10-15）：
   * 「待办类型允许在设置里添加或者删除自定义的类型……同时可以选择类型为无」。
   *
   * 内置的「作业 / 自学 / 考试 / 无」不能删：考试的固定时间、自动排块语义挂在 `exam` 上，
   * 作业/自学是老数据的默认值。老的「其他」已退役（编辑窗那个位置让给「新建类型」），
   * 存量待办在启动时被迁成「无」（见 `domain/Categories` 的文件头）。
   *
   * 删一个自定义类型时，**用了它的待办会改成「无」**（用户拍定），所以确认文案里带上条数。
   */
  private customCategories(): string[] {
    return parseCustomCategories(this.catRaw);
  }

  private addCategory(): void {
    const verdict: CategoryVerdict = validateCategoryName(this.catDraft, this.customCategories());
    if (!verdict.ok) {
      this.catError = verdict.message;
      return;
    }
    const name: string = this.catDraft.trim();
    this.catError = '';
    this.catDraft = '';
    this.persistCategories(addCustomCategory(this.customCategories(), name));
    this.showToast(`已添加类型「${name}」`);
  }

  private armCategoryDelete(name: string): void {
    this.doArmCategoryDelete(name).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'count category failed: %{public}s', JSON.stringify(e));
      this.catPendingDelete = name;
      this.catPendingCount = 0;
    });
  }

  private async doArmCategoryDelete(name: string): Promise<void> {
    this.catPendingCount = await TodoRepo.countByCategory(this.context(), name);
    this.catPendingDelete = name;
  }

  private confirmCategoryDelete(name: string): void {
    this.doConfirmCategoryDelete(name).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'delete category failed: %{public}s', JSON.stringify(e));
      this.showToast('删除失败');
    });
  }

  private async doConfirmCategoryDelete(name: string): Promise<void> {
    const ctx: common.UIAbilityContext = this.context();
    // 先用它的待办改成「无」（不会留下一个永远选不到的孤儿类型）
    await TodoRepo.reassignCategory(ctx, name, TodoCategory.None);
    this.catPendingDelete = '';
    this.catPendingCount = 0;
    await this.persistCategories(removeCustomCategory(this.customCategories(), name));
    this.showToast(`已删除类型「${name}」`);
  }

  private async persistCategories(list: string[]): Promise<void> {
    this.catRaw = (await saveCustomCategories(this.context(), list)).join('\n');
  }

  /** 内置类型的只读胶囊（长得像 ChipButton，但不可点） */
  @Builder
  BuiltinCategoryChip(label: string) {    Text(label)
      .fontSize(12)
      .fontColor('#A9B5C9')
      .backgroundColor('rgba(255,255,255,0.08)')
      .borderRadius(12)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8, bottom: 8 })
  }

  @Builder
  CategoryCard() {    Column() {
      this.SectionTitle('待办类型',
        `内置的四个不能删；自定义的可以加、可以删（最多 ${CATEGORY_MAX_COUNT} 个）。删掉一个类型时，用了它的待办会改成「无」。`)

      Text('内置')
        .fontSize(12)
        .fontColor('#94A0B5')
        .width('100%')
        .margin({ bottom: 6 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(builtinCategoryOptions(), (o: CategoryOption) => {
          this.BuiltinCategoryChip(o.label)
        }, (o: CategoryOption) => `catb-${o.key}`)
      }
      .width('100%')

      Text(`自定义（${this.customCategories().length}）`)
        .fontSize(12)
        .fontColor('#94A0B5')
        .width('100%')
        .margin({ top: 8, bottom: 6 })

      if (this.customCategories().length === 0) {
        Text('还没有自定义类型。下面加一个，或者直接在待办编辑窗里点「＋新建类型」。')
          .fontSize(12)
          .fontColor('#8B97AC')
          .width('100%')
      }

      ForEach(this.customCategories(), (name: string) => {
        Column() {
          Row() {
            Text(name)
              .fontSize(13)
              .fontColor('#F2F5FA')
              .layoutWeight(1)
            Text('删')
              .fontSize(12)
              .fontColor('#FF8080')
              .padding({ left: 10, right: 10 })
              .onClick((): void => this.armCategoryDelete(name))
          }
          .width('100%')
          .padding(10)
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(8)

          if (this.catPendingDelete === name) {
            this.CategoryDeleteConfirmRow(
              this.catPendingCount > 0
                ? `确定删除「${name}」？${this.catPendingCount} 条待办会改成「无」。`
                : `确定删除「${name}」？`,
              (): void => this.confirmCategoryDelete(name))
          }
        }
        .width('100%')
        .margin({ bottom: 6 })
      }, (name: string) => `cat-${name}-${this.catPendingDelete === name}`)

      Row() {
        TextInput({ text: this.catDraft, placeholder: `新类型名（最多 ${CATEGORY_NAME_MAX} 个字）` })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.catDraft = v;
            this.catError = '';
          })
        Button('添加')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .fontSize(13)
          .margin({ left: 8 })
          .onClick((): void => this.addCategory())
      }
      .width('100%')
      .margin({ top: 10 })

      if (this.catError.length > 0) {
        Text(this.catError)
          .fontSize(11)
          .fontColor('#FF8A8A')
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  /**
   * 计划页时间范围卡片（用户要求：「计划页面的上下限也应当可以设置（整半小时时段）
   * （独立于不可排时段）」）。
   *
   * 和「不可排时段」是两件事：这个只管**画哪一段**（显示范围），
   * 不可排时段是「一键找空档」要跳过的区间。所以单独一张卡片、互不影响。
   */
  @Builder
  WindowStepRow(label: string, isStart: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#F2F5FA')
        .layoutWeight(1)
      Button('‹')
        .backgroundColor('rgba(255,255,255,0.12)')
        .fontColor('#7FA8FF')
        .fontSize(15)
        .width(38)
        .height(30)
        .onClick((): void => this.stepPlanWindow(isStart, -WINDOW_SNAP_MIN))
      Text(isStart ? minToHHmm(this.winStart) : minToHHmm(this.winEnd))
        .fontSize(14)
        .fontColor('#EAF0FA')
        .width(64)
        .textAlign(TextAlign.Center)
      Button('›')
        .backgroundColor('rgba(255,255,255,0.12)')
        .fontColor('#7FA8FF')
        .fontSize(15)
        .width(38)
        .height(30)
        .onClick((): void => this.stepPlanWindow(isStart, WINDOW_SNAP_MIN))
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  PlanWindowCard() {
    Column() {
      this.SectionTitle('计划页时间范围',
        '计划网格画哪一段（上下限），按整半小时调。它只管显示范围，和「不可排时段」是两件事。')

      this.WindowStepRow('上边界（最早）', true)
      this.WindowStepRow('下边界（最晚）', false)

      Text(`当前：${minToHHmm(this.winStart)} – ${minToHHmm(this.winEnd)}（共 ${this.windowSpanText()}）`)
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 6 })

      Button('恢复默认 07:00–24:00')
        .backgroundColor('rgba(255,255,255,0.10)')
        .fontColor('#C3CDDE')
        .fontSize(12)
        .height(32)
        .width('100%')
        .margin({ top: 12 })
        .onClick((): void => this.resetPlanWindow())

      Text(`最窄 ${WINDOW_MIN_SPAN / 60} 小时；最晚到 ${minToHHmm(WINDOW_MAX_END)}。`)
        .fontSize(10)
        .fontColor('#7C8798')
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  /**
   * 动画卡片：用户要求"在一个地方一次性关掉"。
   *
   * 关掉之后**所有**动效立刻退化为直接切换（列表增删、抽屉、托盘、页面切换、
   * 打字机、光晕漂移、扫光），不需要重启 App —— 每个动效都在用
   * `dur()` / `curveOrLinear()` 取值，而它们直接读这个开关（见 view/Motion.ets）。
   */
  @Builder
  MotionCard() {
    Column() {
      this.SectionTitle('动画', '关掉之后所有动效都退化为直接切换：列表增删、抽屉、托盘、打字机与背景光晕漂移全部停。')

      Row() {
        Column() {
          Text('界面动画')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
          Text(this.motionOn ? '开着：进出场、碎裂掉出、光晕漂移都在跑' : '已关闭：一切直接切换（更省电）')
            .fontSize(11)
            .fontColor('#94A0B5')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.motionOn })
          .selectedColor('#2E6BE6')
          .onChange((on: boolean): void => {
            persistMotionSetting(this.context(), on).catch((e: Object): void => {
              hilog.warn(DOMAIN, TAG, 'persist motion failed: %{public}s', JSON.stringify(e));
            });
            this.showToast(on ? '动画已开启' : '动画已关闭（所有动效直接切换）');
          })
      }
      .width('100%')
      .padding({ top: 4 })

      Text('不会影响数据的读写与提醒；关掉只是不再播放过渡效果。')
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .margin({ bottom: 12 })
  }

  @Builder
  ReminderCard() {
    Column() {
      this.SectionTitle('提醒',
        '提醒会写进系统日历、由日历负责响铃；每次启动 App 会把未来一段时间的提醒重排一遍。')

      Row() {
        Column() {
          Text('每日简报')
            .fontSize(14)
            .fontColor('#F2F5FA')
          Text('每天一条：今天几节课 + 今天截止什么')
            .fontSize(11)
            .fontColor('#94A0B5')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.remSettings.briefEnabled })
          .onChange((on: boolean): void => {
            this.remSettings.briefEnabled = on;
          })
      }
      .width('100%')

      if (this.remSettings.briefEnabled) {
        this.FieldLabel('简报时间')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(BRIEF_CHOICES, (m: number) => {
            ChipButton({
              text: minToHHmm(m),
              selected: this.remSettings.briefMin === m,
              onTap: (): void => {
                this.remSettings.briefMin = m;
              }
            })
          }, (m: number) => `brief-${m}`)
        }
        .width('100%')
      }

      this.FieldLabel('上课提前多久提醒')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(LEAD_CHOICES, (m: number) => {
          ChipButton({
            text: `${m} 分钟`,
            selected: this.remSettings.classLeadMin === m,
            onTap: (): void => {
              this.remSettings.classLeadMin = m;
            }
          })
        }, (m: number) => `lead-${m}`)
      }
      .width('100%')

      Button('保存提醒设置')
        .backgroundColor('#2E6BE6')
        .fontColor('#FFFFFF')
        .width('100%')
        .margin({ top: 16 })
        .onClick((): void => this.saveRem())
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DeleteConfirmRow(message: string, onConfirm: () => void) {
    Row() {
      Text(message)
        .fontSize(11)
        .fontColor('#FF8A8A')
        .layoutWeight(1)
      Text('取消')
        .fontSize(12)
        .fontColor('#A9B5C9')
        .padding({ left: 10, right: 10 })
        .onClick((): void => {
          this.pendingDeleteKey = '';
        })
      Text('删除')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#D64545')
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .onClick(onConfirm)
    }
    .width('100%')
    .margin({ top: 8 })
  }

  /**
   * 待办类型的删除确认行。
   * ⚠️ 不能复用 `DeleteConfirmRow` —— 它的「取消」写死清的是 `pendingDeleteKey`（不可排时段那个），
   *    拿来给类型用会"点取消关不掉"。
   */
  @Builder
  CategoryDeleteConfirmRow(message: string, onConfirm: () => void) {
    Row() {
      Text(message)
        .fontSize(11)
        .fontColor('#FF8A8A')
        .layoutWeight(1)
      Text('取消')
        .fontSize(12)
        .fontColor('#A9B5C9')
        .padding({ left: 10, right: 10 })
        .onClick((): void => {
          this.catPendingDelete = '';
          this.catPendingCount = 0;
        })
      Text('删除')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#D64545')
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .onClick(onConfirm)
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder
  WallpaperCard() {
    Column() {
      this.SectionTitle('背景',
        '玻璃态要有东西可透才好看。默认是柔和渐变；换成自己的照片后，所有玻璃面会自动跟着变。')

      // 预览：渐变永远在底层（没图时就是它），有图才盖上去 + 同一层可读性薄纱
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: [[PAGE_GRADIENT_A, 0.0], [PAGE_GRADIENT_B, 0.42], [PAGE_GRADIENT_C, 1.0]]
          })
        if (this.wallPreview !== undefined) {
          Image(this.wallPreview)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(WALLPAPER_VEIL)
            .hitTestBehavior(HitTestMode.None)
        }
        // 预览里也放一块玻璃，直观看到"玻璃压在这层背景上"的效果
        Column() {
          Text(this.wallpaper.length > 0 ? '自定义照片' : '默认渐变')
            .fontSize(12)
            .fontColor('#F2F5FA')
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .glassPanelCard()
      }
      .width('100%')
      .height(110)
      .borderRadius(12)
      .clip(true)

      Row() {
        Button('从相册选一张')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .onClick((): void => this.pickWallpaper())
        if (this.wallpaper.length > 0) {
          Button('恢复默认渐变')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.clearWallpaper())
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // 选区域 / 调位置（用户 2026-10-15）。原图不动，只存归一化的位置与缩放。
      if (this.wallpaper.length > 0) {
        Row() {
          Button('调整位置 / 区域')
            .backgroundColor('rgba(46,107,230,0.22)')
            .fontColor('#7FA8FF')
            .layoutWeight(1)
            .onClick((): void => this.openAdjust())
          Button('居中')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => this.persistFocus('0,0,1'))
        }
        .width('100%')
        .margin({ top: 10 })
      }

      Text('照片会拷进 App 内部保存，不联网、也不需要相册权限。')
        .fontSize(11)
        .fontColor('#8B97AC')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
  }


  /**
   * 「调整背景」全屏界面（用户 2026-10-15 拍定：开一个全屏界面，拖动 + 双指缩放 + 滑杆）。
   *
   * 几个刻意的选择：
   *  - 预览层就是**整屏**（说明/按钮浮在它上面），几何用和 PageBackground **同一个纯函数**
   *    算 → 所见即所得，不会"调的时候挺好看、退出去对不上"。
   *  - 连可读性薄纱一起预览：不然调完发现实际更暗。
   *  - 存的是**归一化的焦点**（-1..1）而不是像素：换屏幕/横竖屏都不会跑偏。
   *  - 原图一个字节都不动，随时能再调或点「居中」回默认。
   */
  @Builder
  AdjustOverlay() {
    Stack() {
      // ---- 底层：整屏预览 ----
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: [[PAGE_GRADIENT_A, 0.0], [PAGE_GRADIENT_B, 0.42], [PAGE_GRADIENT_C, 1.0]]
          })
        if (this.adjPixmap !== undefined) {
          Image(this.adjPixmap)
            .width(this.adjGeo().w > 0 ? this.adjGeo().w : '100%')
            .height(this.adjGeo().h > 0 ? this.adjGeo().h : '100%')
            .objectFit(ImageFit.Fill)
            .draggable(false)
            .translate({ x: this.adjGeo().dx, y: this.adjGeo().dy })
        }
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(WALLPAPER_VEIL)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        const w: Length | undefined = newArea.width;
        const h: Length | undefined = newArea.height;
        if (typeof w === 'number' && w > 0) {
          this.adjBoxW = w;
        }
        if (typeof h === 'number' && h > 0) {
          this.adjBoxH = h;
        }
      })
      // 单指拖动 = 选区域；双指捏合 = 缩放（滑杆是给捏合不灵的时候兜底的）
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PanGesture({ fingers: 1 })
            .onActionStart((): void => {
              this.dragFx0 = this.adjFx;
              this.dragFy0 = this.adjFy;
            })
            .onActionUpdate((e: GestureEvent): void => {
              // ⚠️ 全局 `px2vp` 在 API 18 已废弃（会让警告数从 6 变 8，§6.3 的规矩）
              this.dragAdjust(this.getUIContext().px2vp(e.offsetX),
                this.getUIContext().px2vp(e.offsetY));
            }),
          PinchGesture({ fingers: 2 })
            .onActionStart((): void => {
              this.pinchZoom0 = this.adjZoom;
            })
            .onActionUpdate((e: GestureEvent): void => {
              const v: number[] = clampFocus(this.adjFx, this.adjFy, this.pinchZoom0 * e.scale);
              this.adjZoom = v[2];
            })
        )
      )

      // ---- 顶部说明（浮在预览上）。⚠️ 定位壳：根 Stack 默认居中排子节点，
      //      直接 position 会跑偏（§20.5 第 1 条踩过），所以要一层"满屏 + 顶到上边"的壳。
      Column() {
        Column() {
          Text('调整背景')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2F5FA')
          Text('拖动选择区域；双指或下面的滑杆缩放。原图不会被改动。')
            .fontSize(11)
            .fontColor('#C3CDDE')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(14)
        .glassSheet()
      }
      .width('100%')
      .height('100%')
      .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, top: FLOAT_TOP })
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)

      // ---- 底部：缩放滑杆 + 三个按钮（同样用定位壳钉住底边）----
      Column() {
        Column() {
        Row() {
          Text('缩放')
            .fontSize(12)
            .fontColor('#C3CDDE')
            .width(40)
          Slider({
            value: this.adjZoom,
            min: WALLPAPER_MIN_ZOOM,
            max: WALLPAPER_MAX_ZOOM,
            step: 0.05
          })
            .layoutWeight(1)
            .onChange((v: number): void => {
              this.adjZoom = v;
            })
          Text(`${this.adjZoom.toFixed(2)}×`)
            .fontSize(12)
            .fontColor('#7FA8FF')
            .width(56)
            .textAlign(TextAlign.End)
        }
        .width('100%')

        Row() {
          Button('居中')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .fontSize(14)
            .layoutWeight(1)
            .onClick((): void => this.resetAdjust())
          Button('取消')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .fontSize(14)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick((): void => this.cancelAdjust())
          Button('保存')
            .backgroundColor('#2E6BE6')
            .fontColor('#FFFFFF')
            .fontSize(14)
            .layoutWeight(1)
            .margin({ left: 8 })
            .onClick((): void => this.saveAdjust())
        }
        .width('100%')
        .margin({ top: 12 })
        }
        .width('100%')
        .padding(14)
        .glassSheet()
      }
      .width('100%')
      .height('100%')
      .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, bottom: FLOAT_TOP + 8 })
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  RestCard() {
    Column() {
      this.SectionTitle('不可排时段',
        '「一键找空档」会跳过这些时段（午休、吃饭、睡觉…）。')

      if (this.restWindows.length === 0) {
        Text('还没有设置。加几条之后，一键找空档就不会把待办排到饭点或深夜。')
          .fontSize(12)
          .fontColor('#8B97AC')
          .width('100%')
      }

      ForEach(this.restWindows, (w: RestWindow) => {
        Column() {
          Row() {
            Text(w.label)
              .fontSize(13)
              .fontColor('#F2F5FA')
              .width(72)
            Text(this.restWeekdayText(w))
              .fontSize(12)
              .fontColor('#A9B5C9')
              .width(48)
            Text(`${minToHHmm(w.startMin)} – ${minToHHmm(w.endMin)}`)
              .fontSize(12)
              .fontColor('#A9B5C9')
              .layoutWeight(1)
            Text('删')
              .fontSize(12)
              .fontColor('#FF8080')
              .padding({ left: 10, right: 10 })
              .onClick((): void => {
                this.pendingDeleteKey = this.deleteKey(w.id);
              })
          }
          .width('100%')
          .padding(10)
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(8)

          if (this.pendingDeleteKey === this.deleteKey(w.id)) {
            this.DeleteConfirmRow(`确定删除「${w.label} ${this.restWeekdayText(w)}」？`,
              (): void => this.deleteRest(w))
          }
        }
        .width('100%')
        .margin({ bottom: 6 })
      }, (w: RestWindow) =>
              `rest-${w.id}-${w.weekday}-${w.startMin}-${w.endMin}-${w.label}-${this.pendingDeleteKey === this.deleteKey(w.id)}`)

      this.FieldLabel('名称')
      TextInput({ text: this.newRestLabel, placeholder: '午休' })
        .fontColor('#F2F5FA')
        .placeholderColor('#8B97AC')
        .caretColor('#7FA8FF')
        .onChange((v: string): void => {
          this.newRestLabel = v;
        })

      this.FieldLabel('适用哪天')
      Flex({ wrap: FlexWrap.Wrap }) {
        ChipButton({
          text: '每天',
          selected: this.newRestWeekday === 0,
          onTap: (): void => {
            this.newRestWeekday = 0;
          }
        })
        ForEach([1, 2, 3, 4, 5, 6, 7], (wd: number) => {
          ChipButton({
            text: `周${WEEKDAY_CN[wd - 1]}`,
            selected: this.newRestWeekday === wd,
            onTap: (): void => {
              this.newRestWeekday = wd;
            }
          })
        }, (wd: number) => `rw-${wd}`)
      }
      .width('100%')

      this.FieldLabel('时间')
      this.RestTimeRow('开始', true)
      this.RestTimeRow('结束', false)

      Button('添加')
        .backgroundColor('#2E6BE6')
        .fontColor('#FFFFFF')
        .width('100%')
        .margin({ top: 12 })
        .onClick((): void => this.addRest())
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  /**
   * 新手引导入口（用户 2026-10-15：「做一个新手引导……你步步引导」）。
   *
   * 点「开始演练」不是在这里做什么，而是回调 `Index`：它会切到一个**空的沙箱库**
   * （`classout_demo.db`）、灌几门演示课，然后在真实界面底部挂一条步骤引导条。
   * 演练里随便改、随便删；退出时沙箱整个删掉，用户自己的课表一点都不动。
   */
  @Builder
  GuideCard() {
    Column() {
      this.SectionTitle('新手引导',
        '第一次上手？可以在「演练」里走一遍：会开一个沙箱（几门演示课 + 演示待办），你随便改、随便删，退出时整份丢弃。')

      Button('开始演练')
        .backgroundColor('#2E6BE6')
        .fontColor('#FFFFFF')
        .fontSize(14)
        .width('100%')
        .margin({ top: 4 })
        .onClick((): void => this.onStartGuide())

      Text('演练期间右下角会有一条「第 n/N 步」的引导条，跟着点就行；随时可以「退出演练」。')
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  build() {
    Stack() {
      Column() {
        Scroll() {
          Column() {
            // 提示条：不占布局地贴在顶部会跳，所以这里就放在流的开头，
            // 但只有内容出现时才会有高度（用 if 而不是留空位）
            if (this.toast.length > 0) {
              Text(this.toast)
                .fontSize(12)
                .fontColor('#EAF0FA')
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor('rgba(46,107,230,0.22)')
                .borderRadius(8)
                .margin({ bottom: 12 })
            }

            this.WallpaperCard()
            this.MottoCard()
            this.MotionCard()
            this.ReminderCard()
            this.RestCard()
            this.CategoryCard()
            this.PlanWindowCard()
            this.GuideCard()
          }
          .width('100%')
          // 上下都给悬浮浮窗让位；padding 加在**滚动内容**上，卡片才能滑到浮窗下面
          .padding({
            left: 16, right: 16, top: 12 + this.topInset + this.titleH + FLOAT_GAP,
            bottom: 30 + this.bottomInset
          })
          .alignItems(HorizontalAlign.Start)
        }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      }
      .width('100%')
      .height('100%')

      // ================= 浮窗层（不参与内容布局）=================
      // 设置页没有课表那套页头，只有它自己的「设置」标题栏浮在最上面
      Column() {
        // ⚠️ 定位壳：根 Stack 默认居中排子节点，浮窗必须靠"满屏 + 顶到上边"钉住
        Column() {
          Row() {
            Text('设置')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .glassSheet()
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const h: Length | undefined = newArea.height;
            if (typeof h === 'number' && h > 0) {
              this.titleH = h;
            }
          })
        }
        .width('100%')
        .padding({ left: FLOAT_SIDE, right: FLOAT_SIDE, top: this.topInset + FLOAT_TOP })
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .hitTestBehavior(HitTestMode.Transparent)
      // 调整背景的全屏界面：画在页面最上层。
      // ⚠️ 它仍然在**页面内部**，所以开着的时候要让 Index 把悬浮浮窗层挪到内容层之下
      //    （`onModalChange` → `Index.pageModalOpen`，和两个编辑窗同一套路，见 §20.8）。
      if (this.adjusting) {
        this.AdjustOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // 底色交给 Index 的 PageBackground（玻璃要有东西可透），这里保持透明
  }
}
