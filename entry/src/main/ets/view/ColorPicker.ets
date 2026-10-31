import { hexToHsv, hsvToHex, Hsv, PICKER_MAX_SAT, PICKER_MAX_VALUE, PICKER_MIN_SAT } from '../domain/Palette';

/**
 * 学科调色盘的取色器（用户 2026-10-30）。
 *
 * 不是系统弹窗，就是一页内联面板：色相 / 饱和度 / 明度三根滑杆 + 实时预览。
 * 放在宿主组件（设置页 / 课程编辑页）的 Stack 最上层，配一层点外面就取消的遮罩。
 *
 * ⚠️ 明度上限 68%、饱和度下限 30%：本 App 的课程块一律压白字，太亮/太淡都读不清。
 *    这条限制在 `domain/Palette.hsvToHex` 里也夹了一次（纯逻辑有断言）。
 */
@Component
export struct CourseColorPicker {
  /** 打开时的初始颜色（通常是当前颜色） */
  @Prop initial: string = '#2C5FA8';
  @Prop title: string = '自定义颜色';
  onPick: (hex: string) => void = (): void => {};
  onCancel: () => void = (): void => {};

  @State hue: number = 215;
  @State sat: number = 0.60;
  @State val: number = 0.50;

  aboutToAppear(): void {
    const hsv: Hsv = hexToHsv(this.initial);
    this.hue = hsv.h;
    this.sat = Math.min(PICKER_MAX_SAT, Math.max(PICKER_MIN_SAT, hsv.s));
    this.val = Math.min(PICKER_MAX_VALUE, Math.max(0.20, hsv.v));
  }

  private currentHex(): string {
    return hsvToHex(this.hue, this.sat, this.val);
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F5FA')
          .layoutWeight(1)
        Text('✕')
          .fontSize(14)
          .fontColor('#A9B5C9')
          .padding({ left: 14, top: 4, bottom: 4 })
          .onClick((): void => this.onCancel())
      }
      .width('100%')
      .margin({ bottom: 14 })

      // 预览：一块色块 + 白字，所见即所得
      Row() {
        Column() {
          Text('课')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .width(56)
        .height(56)
        .borderRadius(12)
        .backgroundColor(this.currentHex())
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .border({ width: 1, color: 'rgba(255,255,255,0.24)' })

        Column() {
          Text(this.currentHex())
            .fontSize(15)
            .fontColor('#F2F5FA')
          Text('课程块上就是白字压在这个颜色上')
            .fontSize(11)
            .fontColor('#8B97AC')
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14 })
      }
      .width('100%')

      Text('色相')
        .fontSize(12)
        .fontColor('#94A0B5')
        .width('100%')
        .margin({ top: 18, bottom: 4 })
      // 色相条（装饰）：只是让人知道滑杆往左/往右是什么颜色
      Row()
        .width('100%')
        .height(8)
        .borderRadius(4)
        .linearGradient({
          angle: 90,
          colors: [['#D64545', 0.0], ['#E8B25C', 0.17], ['#7BD69A', 0.34],
            ['#2C5FA8', 0.5], ['#6B45A8', 0.67], ['#8A3D6B', 0.84], ['#D64545', 1.0]]
        })
      Slider({ value: this.hue, min: 0, max: 360, step: 1 })
        .selectedColor('#7FA8FF')
        .trackColor('rgba(255,255,255,0.16)')
        .blockColor('#FFFFFF')
        .showTips(true)
        .onChange((v: number): void => {
          this.hue = v;
        })

      Text(`饱和度 ${Math.round(this.sat * 100)}%`)
        .fontSize(12)
        .fontColor('#94A0B5')
        .width('100%')
        .margin({ top: 10, bottom: 4 })
      Slider({ value: this.sat * 100, min: PICKER_MIN_SAT * 100, max: PICKER_MAX_SAT * 100, step: 1 })
        .selectedColor('#7FA8FF')
        .trackColor('rgba(255,255,255,0.16)')
        .blockColor('#FFFFFF')
        .showTips(true)
        .onChange((v: number): void => {
          this.sat = v / 100;
        })

      Text(`明度 ${Math.round(this.val * 100)}%（最高 ${Math.round(PICKER_MAX_VALUE * 100)}%，保证白字看得清）`)
        .fontSize(12)
        .fontColor('#94A0B5')
        .width('100%')
        .margin({ top: 10, bottom: 4 })
      Slider({ value: this.val * 100, min: 20, max: PICKER_MAX_VALUE * 100, step: 1 })
        .selectedColor('#7FA8FF')
        .trackColor('rgba(255,255,255,0.16)')
        .blockColor('#FFFFFF')
        .showTips(true)
        .onChange((v: number): void => {
          this.val = v / 100;
        })

      Row() {
        Button('取消')
          .backgroundColor('rgba(255,255,255,0.14)')
          .fontColor('#C3CDDE')
          .fontSize(14)
          .layoutWeight(1)
          .onClick((): void => this.onCancel())
        Button('就用这个颜色')
          .backgroundColor('#2E6BE6')
          .fontColor('#FFFFFF')
          .fontSize(14)
          .layoutWeight(1)
          .margin({ left: 10 })
          .onClick((): void => this.onPick(this.currentHex()))
      }
      .width('100%')
      .margin({ top: 18 })
    }
    .width('100%')
    .padding(18)
    .backgroundColor('rgba(18,24,36,0.98)')
    .borderRadius(18)
    .border({ width: 1, color: 'rgba(255,255,255,0.16)' })
  }
}
