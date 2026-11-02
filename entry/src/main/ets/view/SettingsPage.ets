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

import { common, bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { storedAbilityContext } from '../util/Ctx';
import { BackHandler, backStack } from '../util/BackStack';
import { PrivacySection, privacySections, privacyUpdatedAt } from '../domain/Privacy';
import { PlanBlock, RestWindow, Todo, TodoCategory, TodoStatus } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { computeWeekSessions, weekOfDate } from '../domain/Timetable';
import { addDays, formatDate, parseDate, today } from '../util/DateUtil';
import { BackupRepo } from '../data/BackupRepo';
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
import { hapticScrollEdge } from '../util/Haptics';
import { pickTime } from '../util/DateTimePicker';
import { MOTTO_DEFAULT, MOTTO_MAX_UNITS, clampMottoUnits, cleanMotto,
  loadConfirmTodoDelete, loadDefaultTab, loadMotto, loadQuickStart, mottoUnits, saveConfirmTodoDelete,
  saveCoursePalette, saveCustomCategories, saveDefaultTab, saveMotto, savePlanWindow, saveQuickStart,
  saveSyncInterval } from '../data/Prefs';
import { normalizeDefaultTab, tabLabel } from '../domain/Launch';
import { DEFAULT_PALETTE, parsePalette } from '../domain/Palette';
import { CourseColorPicker } from './ColorPicker';
import { DEFAULT_WINDOW, TimeWindow, WINDOW_MAX_END, WINDOW_MIN_SPAN, WINDOW_SNAP_MIN } from '../domain/PlanMath';
import { CATEGORY_MAX_COUNT, CATEGORY_NAME_MAX, CategoryOption, CategoryVerdict,
  addCustomCategory, builtinCategoryOptions, parseCustomCategories, removeCustomCategory,
  validateCategoryName } from '../domain/Categories';
import { SYNC_INTERVAL_CHOICES, SYNC_INTERVAL_DEFAULT, SYNC_INTERVAL_MAX, SYNC_INTERVAL_MIN,
  normalizeSyncInterval } from '../domain/SyncCadence';

// 文件内 @Styles（见 Glass.ets 顶部注释：@Styles 不能跨文件 export）
// 深色版。设置页的卡片按用户拍定算"大面" → 保留模糊（`glassPanelCard`），
// 它不是列表行那种"一屏十几张"的密度，多几次背景模糊不影响滚动。
@Styles
function glassPanelCard() {
  .backdropBlur(GLASS_BLUR)
  // 设置页是"一屏多卡"的列表：用比普通玻璃更暗的底，亮壁纸下也读得清
  .backgroundColor('rgba(10,14,26,0.62)')
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: 'rgba(255,255,255,0.14)' })
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
  .backgroundColor('rgba(10,14,26,0.62)')
  .borderRadius(GLASS_RADIUS)
  .border({ width: 1, color: 'rgba(255,255,255,0.14)' })
  .shadow(GLASS_SHADOW_SHEET)
}

const DOMAIN: number = 0x0000;
const TAG: string = 'ClassOUT';

/** 设置首页的一行 */
interface SettingsRowItem {
  icon: Resource;
  title: string;
  value: string;
  action: string;
  danger: boolean;
}

interface SettingsGroupDef {
  title: string;
  kind: string;
}

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
  /** 设置首页的学期/课程/备份行 → 由 Index 打开「管理课程」对应子页 */
  onOpenCourseManager: (view: string) => void = (): void => {};
  /** 重置：自动备份之后由 Index 全清、重建并进沙箱演练 */
  onResetApp: () => Promise<void> = (): Promise<void> => Promise.resolve();
  /** 本页标题栏浮窗量出来的高度 */
  @State titleH: number = H_TITLE;
  /** 设置首页的分组/子页：'' = 首页；其余为子页 key */
  @State subPage: string = '';
  /** 顶部概览：本周课程 / 未完成待办 / 未安排待办 */
  @State ovCourses: number = 0;
  @State ovTodos: number = 0;
  @State ovUnscheduled: number = 0;
  @State semesterName: string = '';
  @State semesterWeeks: number = 0;
  @State courseCount: number = 0;
  /** 重置确认：0 = 警告，1 = 已自动备份，等最终确认 */
  @State resetOpen: boolean = false;
  @State resetStep: number = 0;
  @State resetBusy: boolean = false;
  @State resetBackupPath: string = '';
  @State resetBytes: number = 0;
  /** 管理课程关闭 / 数据变化后，由 Index 递增，让本页重读概览 */
  @StorageLink('settingsRefresh') @Watch('onSettingsRefresh') refreshToken: number = 0;

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
  /** 用户滚动过之后，到顶/底才振动 */
  @State scrollMoved: boolean = false;
  @State scrollContentH: number = 0;
  @State scrollViewH: number = 0;
  private lastScrollY: number = 0;
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
   * 「关于」卡片里的版本号 —— 从**安装包自己**读，不写死（写死迟早和 app.json5 对不上）。
   * 读不到就留空，卡片上那一行不显示。
   */
  @State appVersion: string = '';
  /** 隐私政策浮层开着吗（@Watch 见 `refreshModal`） */
  @State @Watch('refreshModal') privacyOpen: boolean = false;
  /** 系统返回的处理器（注册到 util/BackStack；见 HANDOFF §15.2） */
  private backHandler: BackHandler | undefined = undefined;
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

  /**
   * 日历同步 / 闲置重启的间隔 `n`（分钟），默认 10。
   * 用户 2026-10-16：一个值管两件事 —— 连续用到 n 的整数倍自动同步一次；
   * 闲置超过 n 再回来就重新启动。
   */
  @StorageLink('syncIntervalMin') syncIntervalMin: number = SYNC_INTERVAL_DEFAULT;

  /**
   * 快速启动（用户 2026-10-30）：默认关。开了之后下次打开 App 不播加载动画、
   * 直接进界面，日历同步在后台静默做。
   * ⚠️ `@StorageLink` 键名必须写字面量。
   */
  @StorageLink('quickStart') quickStart: boolean = true;
  /** 删除待办前是否二次确认（默认开；设置页可关） */
  @StorageLink('confirmTodoDelete') confirmTodoDelete: boolean = true;
  /** 打开 App 默认进入哪个标签页（0 课表 / 1 待办 / 2 计划 / 3 设置） */
  @StorageLink('defaultTab') defaultTab: number = 0;
  /** 学科调色盘（10 个全局颜色，`'\n'` 分隔） */
  @StorageLink('coursePalette') paletteRaw: string = '';
  /** 全局调色盘取色器：开着吗 / 正在改第几格 / 初值（@Watch 见 refreshModal） */
  @State @Watch('refreshModal') palettePickerOpen: boolean = false;
  @State palettePickerIndex: number = 0;
  @State palettePickerInitial: string = '#2C5FA8';

  aboutToAppear(): void {
    // 回显已保存的标语（见上面 `savedMotto` 的注释）
    this.mottoDraft = this.savedMotto;
    this.readAppVersion();
    // 系统返回：先关「隐私政策」，再关「调整背景」（见 handleBack）
    this.backHandler = (): boolean => this.handleBack();
    backStack.register(this.backHandler);
    this.refreshPreview();
    this.load();
  }

  private readAppVersion(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read version failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 本页的返回顺序：隐私政策浮层 → 调整背景浮层 → 不管（交回 Index/系统）。
   *
   * ⚠️ 这是 §15.3 那条规矩：**新增任何浮层都要在宿主组件里注册一条**，
   * 否则手势返回会把整个 App 切走（「调整背景」原来就漏了这条）。
   */
  private handleBack(): boolean {
    if (this.privacyOpen) {
      this.privacyOpen = false;
      return true;
    }
    if (this.adjusting) {
      this.adjusting = false;
      return true;
    }
    if (this.resetOpen) {
      if (!this.resetBusy) {
        this.resetOpen = false;
      }
      return true;
    }
    if (this.subPage.length > 0) {
      this.subPage = '';
      return true;
    }
    return false;
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
    // 启动选项：从当前库读回来（演练沙箱里是一份全新的库 → 默认关、默认课表）
    this.quickStart = await loadQuickStart(ctx);
    this.defaultTab = await loadDefaultTab(ctx);
    this.confirmTodoDelete = await loadConfirmTodoDelete(ctx);
    await this.loadOverview(ctx);
    this.loading = false;
  }

  private onSettingsRefresh(): void {
    this.load();
  }

  /** 首页顶部概览：本周实际课次 / 未完成待办 / 还没排进时间的待办 */
  private async loadOverview(ctx: common.UIAbilityContext): Promise<void> {
    const sem = await TimetableRepo.getSemester(ctx);
    if (sem !== undefined) {
      this.semesterName = sem.name;
      this.semesterWeeks = sem.totalWeeks;
      const courses = await TimetableRepo.listCourses(ctx, sem.id);
      this.courseCount = courses.length;
      const rules = await TimetableRepo.listRules(ctx, sem.id);
      const times = await TimetableRepo.listSectionTimes(ctx, sem.id);
      const end: string = formatDate(addDays(parseDate(sem.startDate), sem.totalWeeks * 7 - 1));
      const overrides = await TimetableRepo.listOverridesBetween(ctx, sem.startDate, end);
      const week: number = weekOfDate(sem, today());
      if (week >= 1 && week <= sem.totalWeeks) {
        this.ovCourses = computeWeekSessions(sem, courses, rules, overrides, times, week).length;
      } else {
        this.ovCourses = 0;
      }
    } else {
      this.semesterName = '';
      this.semesterWeeks = 0;
      this.courseCount = 0;
      this.ovCourses = 0;
    }
    const todos: Todo[] = await TodoRepo.listTodos(ctx, 'status != ?', [TodoStatus.Archived]);
    const active: Todo[] = [];
    for (const t of todos) {
      if (t.status !== TodoStatus.Done) {
        active.push(t);
      }
    }
    this.ovTodos = active.length;
    const blocks: PlanBlock[] = await TodoRepo.listAllBlocks(ctx);
    const scheduled: Set<number> = new Set<number>();
    for (const b of blocks) {
      if (b.todoId > 0) {
        scheduled.add(b.todoId);
      }
    }
    let unscheduled: number = 0;
    for (const t of active) {
      if (!scheduled.has(t.id)) {
        unscheduled++;
      }
    }
    this.ovUnscheduled = unscheduled;
  }

  /** 快速启动开关：立刻写内存 + kv（下次启动生效，本次不改当前界面） */
  private toggleQuickStart(on: boolean): void {
    this.quickStart = on;
    saveQuickStart(this.context(), on).then((): void => {
      this.showToast(on ? '快速启动已开（下次启动生效）' : '快速启动已关');
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save quick start failed: %{public}s', JSON.stringify(e));
    });
  }

  private paletteColors(): string[] {
    return parsePalette(this.paletteRaw);
  }

  private openPalettePicker(idx: number): void {
    this.palettePickerIndex = idx;
    this.palettePickerInitial = this.paletteColors()[idx];
    this.palettePickerOpen = true;
  }

  private applyPaletteColor(hex: string): void {
    const list: string[] = this.paletteColors();
    list[this.palettePickerIndex] = hex;
    saveCoursePalette(this.context(), list).then((clean: string[]): void => {
      this.paletteRaw = clean.join('\n');
      this.palettePickerOpen = false;
      this.showToast('调色盘已更新（所有用这个色的课都变了）');
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save palette failed: %{public}s', JSON.stringify(e));
      this.showToast('保存失败');
    });
  }

  private resetPalette(): void {
    saveCoursePalette(this.context(), DEFAULT_PALETTE).then((clean: string[]): void => {
      this.paletteRaw = clean.join('\n');
      this.showToast('调色盘已恢复默认');
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'reset palette failed: %{public}s', JSON.stringify(e));
    });
  }

  /** 默认进入的标签：同样立刻落盘 */
  private pickDefaultTab(tab: number): void {
    const n: number = normalizeDefaultTab(tab);
    this.defaultTab = n;
    saveDefaultTab(this.context(), n).then((v: number): void => {
      this.defaultTab = v;
      this.showToast(`打开 App 默认进入：${tabLabel(v)}`);
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, TAG, 'save default tab failed: %{public}s', JSON.stringify(e));
    });
  }

  /** 弹一条会自动消失的提示（不占布局，避免整页上下跳） */
  aboutToDisappear(): void {
    if (this.backHandler !== undefined) {
      backStack.unregister(this.backHandler);
      this.backHandler = undefined;
    }
    // 组件销毁（切标签）时浮层也跟着没了，别把"有浮层"的状态留给 Index
    this.onModalChange(false);
  }

  /** 两个全屏浮层（调整背景 / 隐私政策）任一开着，都要让 Index 把悬浮浮窗层挪下去 */
  private refreshModal(): void {
    this.onModalChange(this.adjusting || this.privacyOpen || this.palettePickerOpen);
  }

  private onAdjustChanged(): void {
    this.refreshModal();
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
  /**
   * 「启动」卡片（用户 2026-10-30）：快速启动 + 默认进入哪个界面。
   */
  @Builder
  LaunchCard() {
    Column() {
      this.SectionTitle('启动',
        '快速启动打开后，点图标会直接进界面，不再播一开始的加载动画；日历同步在后台静默做。')

      Row() {
        Column() {
          Text('快速启动')
            .fontSize(14)
            .fontColor('#F2F5FA')
          Text(this.quickStart
            ? '打开直接进界面；启动时的同步在后台做，不挡操作（默认）'
            : '关：打开时完整播放加载动画')
            .fontSize(11)
            .fontColor('#94A0B5')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.quickStart })
          .onChange((on: boolean): void => this.toggleQuickStart(on))
      }
      .width('100%')

      this.FieldLabel('打开 App 默认进入')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach([0, 1, 2, 3], (t: number) => {
          ChipButton({
            text: tabLabel(t),
            selected: this.defaultTab === t,
            onTap: (): void => this.pickDefaultTab(t)
          })
        }, (t: number) => `dt-${t}-${this.defaultTab === t}`)
      }
      .width('100%')

      Text('改完立刻存，下次打开生效；「闲置后重新启动」也会遵守这里的选择。')
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 12 })
  }

  /**
   * 学科调色盘（用户 2026-10-30）：10 个全局颜色，改一格所有用它的课一起变。
   * 每门课还能在「管理课程 → 编辑课程」里单独覆盖。
   */
  @Builder
  PaletteCard() {
    Column() {
      this.SectionTitle('学科调色盘',
        '这 10 个颜色就是所有课程的颜色。点一格可以调色；改一格，用这个颜色的课都会跟着变。')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.paletteColors(), (col: string, idx: number) => {
          Text(' ')
            .width(38)
            .height(38)
            .backgroundColor(col)
            .borderRadius(19)
            .border({ width: 1, color: 'rgba(255,255,255,0.22)' })
            .margin({ right: 10, bottom: 10 })
            .onClick((): void => this.openPalettePicker(idx))
        }, (col: string, idx: number) => `pal-${idx}-${col}`)
      }
      .width('100%')

      Row() {
        Text('想给某门课单独调色？到「管理课程 → 编辑课程 → 颜色」里点「调色…」。')
          .fontSize(11)
          .fontColor('#8B97AC')
          .layoutWeight(1)
        Text('恢复默认')
          .fontSize(12)
          .fontColor('#A9B5C9')
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .onClick((): void => this.resetPalette())
      }
      .width('100%')
      .margin({ top: 2 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 12 })
  }

  @Builder
  DeleteConfirmCard() {
    Column() {
      this.SectionTitle('删除待办前询问',
        '待办左滑删除、或从编辑窗删除时，先弹一次确认。')
      Row() {
        Column() {
          Text('删除前先问我')
            .fontSize(14)
            .fontColor('#F2F5FA')
          Text(this.confirmTodoDelete ? '开：左滑删除会先确认' : '关：左滑直接删除（仍会播放碎裂动画）')
            .fontSize(11)
            .fontColor('#94A0B5')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.confirmTodoDelete })
          .onChange((on: boolean): void => {
            this.confirmTodoDelete = on;
            saveConfirmTodoDelete(this.context(), on).catch((e: Object): void => {
              hilog.warn(DOMAIN, TAG, 'save confirm delete failed: %{public}s', JSON.stringify(e));
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
  }

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
        '课程和计划块会按「整段时间」写进系统日历，由日历提前提醒；每次启动 App 会把未来一段时间的日程重排一遍。')

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

      this.FieldLabel('提前多久提醒（上课 / 计划块）')
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
   * 日历同步卡片：
   * `n` 分钟同时管两件事 —— ① 连续使用到 n 的整数倍时自动同步一次；
   * ② 闲置超过 n 再回到前台就重新启动（重新补生成待办并同步日历）。
   */
  @Builder
  SyncCard() {
    Column() {
      // ⚠️ 副标题里**不能塞 `this.syncIntervalMin`**：`@Builder` 的参数按值传入、
      // 首次渲染后固化，改完间隔这一行会一直显示旧值（真机实测）。
      // 动态的数字放到下面那行普通 Text 里（它每次都重新求值）。
      this.SectionTitle('日历同步',
        '连续使用到设定间隔的整数倍时会自动同步一次（页面上方会弹出提示）；'
        + '闲置超过设定间隔后再次打开，App 会重新启动一次，好让提醒始终是最新的。')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(SYNC_INTERVAL_CHOICES, (m: number) => {
          ChipButton({
            text: `${m} 分钟`,
            selected: this.syncIntervalMin === m,
            onTap: (): void => this.pickSyncInterval(m)
          })
        }, (m: number) => `sync-${m}-${this.syncIntervalMin === m}`)
      }
      .width('100%')

      Text(`当前：每 ${this.syncIntervalMin} 分钟同步一次（默认 ${SYNC_INTERVAL_DEFAULT} 分钟）`)
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 8 })

      Text('页头「⟳ 立即与日历同步」可以随时手动同步一次。')
        .fontSize(11)
        .fontColor('#8B97AC')
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(16)
    .glassPanelCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  private pickSyncInterval(m: number): void {
    const n: number = normalizeSyncInterval(m);
    this.syncIntervalMin = n;
    saveSyncInterval(this.context(), n).then((saved: number): void => {
      this.syncIntervalMin = saved;
      this.showToast(`日历同步间隔：每 ${saved} 分钟`);
    }).catch((e: Object): void => {
      hilog.warn(DOMAIN, TAG, 'save sync interval failed: %{public}s', JSON.stringify(e));
      this.showToast('保存失败');
    });
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

      Text('演练期间右下角会有一条「第 n/N 步」的引导条，跟着点就行；计划页的双指缩放（日 / 三日 / 周）也在里面。随时可以「退出演练」。')
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

  /**
   * 「关于」卡片：版本 + 隐私政策入口。
   *
   * 上架（应用市场）要求应用内有隐私政策可看 + 一个可访问的链接；
   * 正文在 `domain/Privacy.ets`，仓库根目录的 `PRIVACY.md` 是同一份（填链接用那份）。
   */
  @Builder
  AboutCard() {
    Column() {
      this.SectionTitle('关于', '本应用纯离线运行：不联网、不上传、不需要账号，也不收集任何信息。')

      Row() {
        Text('ClassOUT')
          .fontSize(14)
          .fontColor('#F2F5FA')
        Blank()
        Text(this.appVersion.length > 0 ? `v${this.appVersion}` : '')
          .fontSize(12)
          .fontColor('#8B97AC')
      }
      .width('100%')

      Row() {
        Text('隐私政策')
          .fontSize(13)
          .fontColor('#7FA8FF')
          .layoutWeight(1)
          .onClick((): void => {
            this.privacyOpen = true;
          })
        Text('MIT 许可')
          .fontSize(12)
          .fontColor('#8B97AC')
      }
      .width('100%')
      .padding({ top: 12 })

      Text('隐私政策正文也在仓库根目录的 PRIVACY.md（应用市场里填链接用那份）。')
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

  /**
   * 隐私政策全屏浮层。
   * 用**不透明**深色底：政策是要逐字读的东西，玻璃在这里只会碍事（§16.2 的取舍）。
   */
  @Builder
  PrivacyOverlay() {
    Column() {
      Row() {
        Text('隐私政策')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
        Text('✕')
          .fontSize(14)
          .fontColor('#A9B5C9')
          .padding({ left: 14, top: 4, bottom: 4 })
          .onClick((): void => {
            this.privacyOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll() {
        Column() {
          Text(`更新日期：${privacyUpdatedAt()}`)
            .fontSize(11)
            .fontColor('#8B97AC')
            .width('100%')
            .margin({ bottom: 12 })

          ForEach(privacySections(), (s: PrivacySection) => {
            Text(s.heading)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
              .width('100%')
              .margin({ top: 12, bottom: 4 })
            Text(s.body)
              .fontSize(12)
              .fontColor('#C3CDDE')
              .lineHeight(20)
              .width('100%')
          }, (s: PrivacySection) => `pv-${s.heading}`)

          Button('关闭')
            .backgroundColor('rgba(255,255,255,0.14)')
            .fontColor('#C3CDDE')
            .fontSize(14)
            .width('100%')
            .margin({ top: 20, bottom: 12 })
            .onClick((): void => {
              this.privacyOpen = false;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        const h: Length | undefined = newArea.height;
        if (typeof h === 'number' && h > 0) {
          this.scrollViewH = h;
        }
      })
      .onScroll((xOffset: number, yOffset: number): void => {
        this.scrollMoved = true;
        const max: number = this.scrollContentH - this.scrollViewH;
        if (this.scrollContentH > this.scrollViewH + 4) {
          if (yOffset <= 1 && this.lastScrollY > 1) {
            hapticScrollEdge();
          } else if (yOffset >= max - 1 && this.lastScrollY < max - 1) {
            hapticScrollEdge();
          }
        }
        this.lastScrollY = yOffset;
      })
      .onReachStart((): void => {
        if (this.scrollMoved) {
          hapticScrollEdge();
        }
      })
      .onScrollStart((): void => {
        this.scrollMoved = true;
      })
      .onScrollEdge((side: Edge): void => {
        if (this.scrollMoved) {
          hapticScrollEdge();
        }
      })
      .onReachEnd((): void => {
        if (this.scrollMoved) {
          hapticScrollEdge();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0E1420')
  }

  // ---------------- 设置首页：分组列表 + 子页 ----------------

  private subTitle(): string {
    switch (this.subPage) {
      case 'motto': return '首页标语';
      case 'categories': return '待办类型';
      case 'deleteConfirm': return '删除待办前询问';
      case 'planWindow': return '计划页时间范围';
      case 'launch': return '启动';
      case 'palette': return '学科调色盘';
      case 'motion': return '动画';
      case 'reminder': return '学习提醒';
      case 'wallpaper': return '背景';
      case 'rest': return '不可排时段';
      case 'sync': return '日历同步';
      case 'guide': return '新手引导';
      case 'about': return '关于我们';
      default: return '设置';
    }
  }

  private onRow(action: string): void {
    switch (action) {
      case 'semester':
        this.onOpenCourseManager('semester');
        return;
      case 'courses':
        this.onOpenCourseManager('courses');
        return;
      case 'backup':
        this.onOpenCourseManager('backup');
        return;
      case 'reset':
        this.resetStep = 0;
        this.resetOpen = true;
        return;
      default:
        this.subPage = action;
    }
  }

  private termRows(): SettingsRowItem[] {
    return [
      {
        icon: $r('app.media.ic_term'), title: '学期设置',
        value: this.semesterName.length > 0 ? this.semesterName : '', action: 'semester', danger: false
      },
      {
        icon: $r('app.media.ic_course'), title: '课程管理',
        value: this.courseCount > 0 ? `${this.courseCount} 门` : '', action: 'courses', danger: false
      },
      {
        icon: $r('app.media.ic_palette'), title: '学科调色盘',
        value: '10 色', action: 'palette', danger: false
      }
    ];
  }

  private planRows(): SettingsRowItem[] {
    return [
      {
        icon: $r('app.media.ic_plan'), title: '计划页时间范围',
        value: `${minToHHmm(this.winStart)}–${minToHHmm(this.winEnd)}`,
        action: 'planWindow', danger: false
      },
      {
        icon: $r('app.media.ic_rest'), title: '不可排时段',
        value: this.restWindows.length > 0 ? `${this.restWindows.length} 条` : '未设置',
        action: 'rest', danger: false
      },
      {
        icon: $r('app.media.ic_category'), title: '待办类型',
        value: `${builtinCategoryOptions().length + parseCustomCategories(this.catRaw).length} 个`,
        action: 'categories', danger: false
      },
      {
        icon: $r('app.media.ic_confirm'), title: '删除待办前询问',
        value: this.confirmTodoDelete ? '开' : '关', action: 'deleteConfirm', danger: false
      }
    ];
  }

  private lookRows(): SettingsRowItem[] {
    return [
      {
        icon: $r('app.media.ic_wallpaper'), title: '背景',
        value: this.wallpaper.length > 0 ? '自定义' : '默认',
        action: 'wallpaper', danger: false
      },
      {
        icon: $r('app.media.ic_motto'), title: '首页标语',
        value: this.savedMotto === MOTTO_DEFAULT ? '默认' : this.savedMotto,
        action: 'motto', danger: false
      },
      {
        icon: $r('app.media.ic_motion'), title: '动画',
        value: this.motionOn ? '开' : '关',
        action: 'motion', danger: false
      },
      {
        icon: $r('app.media.ic_launch'), title: '启动',
        value: `快速启动${this.quickStart ? '开' : '关'} · 默认${tabLabel(this.defaultTab)}`,
        action: 'launch', danger: false
      }
    ];
  }

  private careRows(): SettingsRowItem[] {
    return [
      {
        icon: $r('app.media.ic_bell'), title: '学习提醒',
        value: `提前 ${this.remSettings.classLeadMin} 分钟`,
        action: 'reminder', danger: false
      },
      {
        icon: $r('app.media.ic_sync'), title: '日历同步',
        value: `每 ${this.syncIntervalMin} 分钟`,
        action: 'sync', danger: false
      }
    ];
  }

  private dataRows(): SettingsRowItem[] {
    return [
      {
        icon: $r('app.media.ic_backup'), title: '本地备份与恢复',
        value: 'JSON', action: 'backup', danger: false
      },
      {
        icon: $r('app.media.ic_guide'), title: '新手引导',
        value: '演练', action: 'guide', danger: false
      },
      {
        icon: $r('app.media.ic_about'), title: '关于我们',
        value: this.appVersion.length > 0 ? `v${this.appVersion}` : '',
        action: 'about', danger: false
      },
      {
        icon: $r('app.media.ic_reset'), title: '重置应用并重新引导',
        value: '', action: 'reset', danger: true
      }
    ];
  }

  @Builder
  SettingRow(it: SettingsRowItem) {
    Row() {
      Image(it.icon)
        .width(19)
        .height(19)
        .objectFit(ImageFit.Contain)
        .margin({ right: 12 })
      Text(it.title)
        .fontSize(15)
        .fontColor(it.danger ? '#FF6B6B' : '#F2F5FA')
        .layoutWeight(1)
      if (it.value.length > 0) {
        Text(it.value)
          .fontSize(11)
          .fontColor('#8B97AC')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 150 })
          .margin({ left: 8 })
      }
      Text('›')
        .fontSize(18)
        .fontColor(it.danger ? '#FF6B6B' : '#6F7C91')
        .margin({ left: 6 })
    }
    .width('100%')
    .height(54)
    .padding({ left: 14, right: 12 })
    .onClick((): void => this.onRow(it.action))
  }

  private groupDefs(): SettingsGroupDef[] {
    return [
      { title: '学期与课程', kind: 'term' },
      { title: '计划与待办', kind: 'plan' },
      { title: '外观与启动', kind: 'look' },
      { title: '提醒与同步', kind: 'care' },
      { title: '数据与帮助', kind: 'data' }
    ];
  }

  private rowsOf(kind: string): SettingsRowItem[] {
    switch (kind) {
      case 'term': return this.termRows();
      case 'plan': return this.planRows();
      case 'look': return this.lookRows();
      case 'care': return this.careRows();
      case 'data': return this.dataRows();
      default: return [];
    }
  }

  private groupSig(kind: string): string {
    let s: string = '';
    for (const it of this.rowsOf(kind)) {
      s += `${it.title}:${it.value};`;
    }
    return s;
  }

  @Builder
  SettingGroup(title: string, kind: string) {
    Column() {
      Text(title)
        .fontSize(11)
        .fontColor('#7E8A9F')
        .width('100%')
        .padding({ left: 4, bottom: 6 })
      Column() {
        ForEach(this.rowsOf(kind), (it: SettingsRowItem, idx: number) => {
          this.SettingRow(it)
          if (idx < this.rowsOf(kind).length - 1) {
            Divider()
              .strokeWidth(1)
              .color('rgba(255,255,255,0.06)')
              .margin({ left: 45 })
          }
        }, (it: SettingsRowItem) => `${it.action}-${it.title}-${it.value}`)
      }
      .width('100%')
      .glassPanelCard()
    }
    .width('100%')
    .margin({ bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  OverviewCard() {
    Row() {
      Column() {
        Text(`${this.ovCourses}`)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F5FA')
        Text('本周课程')
          .fontSize(11)
          .fontColor('#8B97AC')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Divider().vertical(true).height(30).color('rgba(255,255,255,0.10)')
      Column() {
        Text(`${this.ovTodos}`)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F5FA')
        Text('待办作业')
          .fontSize(11)
          .fontColor('#8B97AC')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      Divider().vertical(true).height(30).color('rgba(255,255,255,0.10)')
      Column() {
        Text(`${this.ovUnscheduled}`)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F5FA')
        Text('待安排')
          .fontSize(11)
          .fontColor('#8B97AC')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .glassPanelCard()
    .margin({ bottom: 16 })
  }

  @Builder
  SettingsHome() {
    this.OverviewCard()
    ForEach(this.groupDefs(), (g: SettingsGroupDef) => {
      this.SettingGroup(g.title, g.kind)
    }, (g: SettingsGroupDef) => `${g.kind}-${this.groupSig(g.kind)}`)
  }

  @Builder
  SettingsSubPage() {
    if (this.subPage === 'motto') {
      this.MottoCard()
    } else if (this.subPage === 'categories') {
      this.CategoryCard()
    } else if (this.subPage === 'deleteConfirm') {
      this.DeleteConfirmCard()
    } else if (this.subPage === 'planWindow') {
      this.PlanWindowCard()
    } else if (this.subPage === 'launch') {
      this.LaunchCard()
    } else if (this.subPage === 'palette') {
      this.PaletteCard()
    } else if (this.subPage === 'motion') {
      this.MotionCard()
    } else if (this.subPage === 'reminder') {
      this.ReminderCard()
    } else if (this.subPage === 'wallpaper') {
      this.WallpaperCard()
    } else if (this.subPage === 'rest') {
      this.RestCard()
    } else if (this.subPage === 'sync') {
      this.SyncCard()
    } else if (this.subPage === 'guide') {
      this.GuideCard()
    } else if (this.subPage === 'about') {
      this.AboutCard()
    }
  }

  private async prepareReset(): Promise<void> {
    if (this.resetBusy) {
      return;
    }
    this.resetBusy = true;
    try {
      const ctx: common.UIAbilityContext = this.context();
      this.resetBytes = await BackupRepo.exportToFile(ctx);
      this.resetBackupPath = BackupRepo.backupFilePath(ctx);
      this.resetStep = 1;
      this.showToast('已自动备份，请确认重置');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'reset backup failed: %{public}s', JSON.stringify(e));
      this.showToast('自动备份失败，未重置');
    }
    this.resetBusy = false;
  }

  private async finishReset(): Promise<void> {
    if (this.resetBusy) {
      return;
    }
    this.resetBusy = true;
    try {
      await this.onResetApp();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'reset failed: %{public}s', JSON.stringify(e));
      this.showToast('重置失败，数据未清空');
      this.resetBusy = false;
      this.resetOpen = false;
    }
  }

  @Builder
  ResetConfirm() {
    Column() {
      Column() {
        Text('重置应用并重新引导')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF8A8A')
          .width('100%')
        if (this.resetStep === 0) {
          Text('会先自动导出当前数据的 JSON 备份，然后清空全部课表 / 待办 / 计划 / 设置，'
            + '原地重建并从沙箱新手演练开始。')
            .fontSize(12)
            .fontColor('#CBD6E8')
            .lineHeight(19)
            .width('100%')
            .margin({ top: 10 })
          Text('备份会保留，可在「本地备份与恢复」里恢复。')
            .fontSize(11)
            .fontColor('#8B97AC')
            .width('100%')
            .margin({ top: 8 })
          Row() {
            Button('取消')
              .backgroundColor('rgba(255,255,255,0.10)')
              .fontColor('#CBD6E8')
              .fontSize(13)
              .layoutWeight(1)
              .onClick((): void => {
                this.resetOpen = false;
                this.resetStep = 0;
              })
            Button(this.resetBusy ? '正在备份…' : '自动备份并继续')
              .backgroundColor('#D64545')
              .fontColor('#FFFFFF')
              .fontSize(13)
              .layoutWeight(1)
              .enabled(!this.resetBusy)
              .onClick((): void => {
                this.prepareReset();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        } else {
          Text(`已自动备份（${this.resetBytes} 字节）。`)
            .fontSize(13)
            .fontColor('#7ED6A5')
            .width('100%')
            .margin({ top: 10 })
          Text(this.resetBackupPath)
            .fontSize(10)
            .fontColor('#8B97AC')
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
          Text('确认后会清空全部数据与设置，并进入沙箱新手演练。')
            .fontSize(12)
            .fontColor('#CBD6E8')
            .width('100%')
            .margin({ top: 10 })
          Row() {
            Button('取消')
              .backgroundColor('rgba(255,255,255,0.10)')
              .fontColor('#CBD6E8')
              .fontSize(13)
              .layoutWeight(1)
              .onClick((): void => {
                this.resetOpen = false;
                this.resetStep = 0;
              })
            Button(this.resetBusy ? '正在重置…' : '确认重置')
              .backgroundColor('#D64545')
              .fontColor('#FFFFFF')
              .fontSize(13)
              .layoutWeight(1)
              .enabled(!this.resetBusy)
              .onClick((): void => {
                this.finishReset();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
      }
      .width('86%')
      .padding(18)
      .glassPanelCard()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(6,10,18,0.62)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
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

            if (this.subPage.length === 0) {
              this.SettingsHome()
            } else {
              this.SettingsSubPage()
            }
          }
          .width('100%')
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const h: Length | undefined = newArea.height;
            if (typeof h === 'number' && h > 0) {
              this.scrollContentH = h;
            }
          })
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
            if (this.subPage.length > 0) {
              Text('‹ 返回')
                .fontSize(13)
                .fontColor('#7FA8FF')
                .margin({ right: 12 })
                .onClick((): void => {
                  this.subPage = '';
                })
            }
            Text(this.subPage.length > 0 ? this.subTitle() : '设置')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F5FA')
            Blank()
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

      // 隐私政策浮层：同样画在页面内部，所以也接上了 onModalChange（见 refreshModal）
      if (this.privacyOpen) {
        this.PrivacyOverlay()
      }

      // 重置确认（全屏遮罩 + 玻璃卡；自动备份后才让最终确认）
      if (this.resetOpen) {
        this.ResetConfirm()
      }

      // 全局调色盘的取色器（用户 2026-10-30）
      if (this.palettePickerOpen) {
        Column() {
          Column() {
            CourseColorPicker({
              initial: this.palettePickerInitial,
              title: `调色盘第 ${this.palettePickerIndex + 1} 格`,
              onPick: (hex: string): void => this.applyPaletteColor(hex),
              onCancel: (): void => {
                this.palettePickerOpen = false;
              }
            })
          }
          .width('90%')
          .onClick((): void => {})
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(12,18,28,0.55)')
        .onClick((): void => {
          this.palettePickerOpen = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    // 底色交给 Index 的 PageBackground（玻璃要有东西可透），这里保持透明
  }
}
