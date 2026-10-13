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
import { GLASS_CARD_BLUR, GLASS_CARD_EDGE, GLASS_CARD_RADIUS, GLASS_CARD_SHADOW,
  GLASS_CARD_TINT, GLASS_PANEL_BLUR, GLASS_PANEL_EDGE, GLASS_PANEL_TINT } from './Glass';

// 文件内 @Styles（见 Glass.ets 顶部注释：@Styles 不能跨文件 export）
@Styles
function glassCard() {
  .backgroundBlurStyle(GLASS_CARD_BLUR)
  .backgroundColor(GLASS_CARD_TINT)
  .borderRadius(GLASS_CARD_RADIUS)
  .border({ width: 1, color: GLASS_CARD_EDGE })
  .shadow(GLASS_CARD_SHADOW)
}

@Styles
function glassPanel() {
  .backgroundBlurStyle(GLASS_PANEL_BLUR)
  .backgroundColor(GLASS_PANEL_TINT)
  .border({ width: 1, color: GLASS_PANEL_EDGE })
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
  /** toast 自动消失的定时器（-1 = 没在计时） */
  private toastTimer: number = -1;

  aboutToAppear(): void {
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
        .fontColor('#12161F')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor('#8A94A6')
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
      .fontColor('#8A94A6')
      .width('100%')
      .margin({ top: 12, bottom: 4 })
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
            .fontColor('#12161F')
          Text('每天一条：今天几节课 + 今天截止什么')
            .fontSize(11)
            .fontColor('#8A94A6')
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
    .glassCard()
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DeleteConfirmRow(message: string, onConfirm: () => void) {
    Row() {
      Text(message)
        .fontSize(11)
        .fontColor('#C0392B')
        .layoutWeight(1)
      Text('取消')
        .fontSize(12)
        .fontColor('#5A6478')
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
  RestCard() {
    Column() {
      this.SectionTitle('不可排时段',
        '「一键找空档」会跳过这些时段（午休、吃饭、睡觉…）。')

      if (this.restWindows.length === 0) {
        Text('还没有设置。加几条之后，一键找空档就不会把待办排到饭点或深夜。')
          .fontSize(12)
          .fontColor('#98A2B3')
          .width('100%')
      }

      ForEach(this.restWindows, (w: RestWindow) => {
        Column() {
          Row() {
            Text(w.label)
              .fontSize(13)
              .fontColor('#12161F')
              .width(72)
            Text(this.restWeekdayText(w))
              .fontSize(12)
              .fontColor('#5A6478')
              .width(48)
            Text(`${minToHHmm(w.startMin)} – ${minToHHmm(w.endMin)}`)
              .fontSize(12)
              .fontColor('#5A6478')
              .layoutWeight(1)
            Text('删')
              .fontSize(12)
              .fontColor('#D64545')
              .padding({ left: 10, right: 10 })
              .onClick((): void => {
                this.pendingDeleteKey = this.deleteKey(w.id);
              })
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#F7F8FA')
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
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.newRestStart = v;
          })
        Text('–')
          .fontSize(14)
          .fontColor('#8A94A6')
          .margin({ left: 8, right: 8 })
        TextInput({ text: this.newRestEnd, placeholder: '13:00' })
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
    .glassCard()
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#12161F')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .glassPanel()

      Scroll() {
        Column() {
          // 提示条：不占布局地贴在顶部会跳，所以这里就放在流的开头，
          // 但只有内容出现时才会有高度（用 if 而不是留空位）
          if (this.toast.length > 0) {
            Text(this.toast)
              .fontSize(12)
              .fontColor('#1B2430')
              .width('100%')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor('#EAF1FF')
              .borderRadius(8)
              .margin({ bottom: 12 })
          }

          this.ReminderCard()
          this.RestCard()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    // 底色交给 Index 的 PageBackground（玻璃要有东西可透），这里保持透明
  }
}
