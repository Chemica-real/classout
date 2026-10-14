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
import { RestWindow } from '../model/Types';
import { TimetableRepo } from '../data/TimetableRepo';
import { ReminderSettings, loadReminderSettings, saveReminderSettings } from '../domain/ReminderScheduler';
import { Validation, validateRestWindow } from '../domain/Validate';
import { WEEKDAY_CN, hhmmToMin, minToHHmm } from '../util/DateUtil';
import { ChipButton } from './ChipButton';
import { image } from '@kit.ImageKit';
import { WallpaperRepo } from '../data/WallpaperRepo';
import { PAGE_GRADIENT_A, PAGE_GRADIENT_B, PAGE_GRADIENT_C, WALLPAPER_VEIL } from './Glass';
import { GLASS_BLUR, GLASS_EDGE_STRONG, GLASS_RADIUS, GLASS_SHADOW_ROW, GLASS_SHADOW_SHEET,
  GLASS_TINT_PANEL, GLASS_TINT_SHEET } from './Glass';
import { FLOAT_GAP, FLOAT_SIDE, FLOAT_TOP, H_TITLE } from './Float';
import { persistMotionSetting } from './Motion';
import { MOTTO_DEFAULT, MOTTO_MAX_UNITS, clampMottoUnits, cleanMotto, loadMotto, mottoUnits,
  saveMotto } from '../data/Prefs';

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
  /** toast 自动消失的定时器（-1 = 没在计时） */
  private toastTimer: number = -1;
  /**
   * 动画总开关（用户要求"可在设置中一次性关闭"）。
   * ⚠️ `@StorageLink` 的键名必须写字面量 —— 详情见 view/Motion.ets。
   */
  @StorageLink('motionOn') motionOn: boolean = true;
  /** 首页标语的就地编辑副本（保存前不动 AppStorage，免得打字时就改到加载页） */
  @State mottoDraft: string = MOTTO_DEFAULT;

  aboutToAppear(): void {
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
      this.showToast('时间格式应为 HH:mm，比如 12:00');
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
        '提醒写进系统日历（代理提醒对侧载应用配额为 0）。每次启动 App 会把未来一段时间的提醒重排一遍。')

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
      }, (w: RestWindow) => `rest-${w.id}-${this.pendingDeleteKey === this.deleteKey(w.id)}`)

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

      Row() {
        TextInput({ text: this.newRestStart, placeholder: '12:00' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.newRestStart = v;
          })
        Text('–')
          .fontSize(14)
          .fontColor('#94A0B5')
          .margin({ left: 8, right: 8 })
        TextInput({ text: this.newRestEnd, placeholder: '13:00' })
          .fontColor('#F2F5FA')
          .placeholderColor('#8B97AC')
          .caretColor('#7FA8FF')
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.newRestEnd = v;
          })
      }
      .width('100%')
      .margin({ top: 10 })

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
    }
    .width('100%')
    .height('100%')
    // 底色交给 Index 的 PageBackground（玻璃要有东西可透），这里保持透明
  }
}
