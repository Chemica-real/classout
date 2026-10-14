import { ChipButton } from './ChipButton';

/**
 * 1–12 节的节次选择器：`from`–`to`（含两端）之间的数字会被选中。
 *
 * ★ 为什么要有这个文件：它原来是一个 `@Builder SectionPicker(from, to, onPick)`，
 *   而 **`@Builder` 的参数是按值传入的，首次渲染后就固化了**（同 `ChipButton.ets` 顶部的说明）。
 *   于是「课表页点课程 → 起 / 止节次」里点数字：状态其实改了，高亮却停在打开抽屉那一刻，
 *   看着像"点了没反应"（用户实测反馈）。
 *
 *   正解和 `ChipButton` 一样 —— 做成真正的自定义组件，用 `@Prop` 接收 `from` / `to`：
 *   父组件的 `moveStart` / `moveEnd` / `extraStart` / `extraEnd` 一变，这里就重新渲染。
 *   `onPick` 是函数，不参与响应式，所以按普通成员传。
 */
@Component
export struct SectionPicker {
  /** 选中区间的起点节次（含） */
  @Prop from: number = 1;
  /** 选中区间的终点节次（含） */
  @Prop to: number = 1;
  /** 点了某一节：把节次报回调用方 */
  onPick: (sec: number) => void = (): void => {};

  build() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], (sec: number) => {
        ChipButton({
          text: `${sec}`,
          selected: sec >= this.from && sec <= this.to,
          onTap: (): void => {
            this.onPick(sec);
          }
        })
      }, (sec: number) =>
      // 选中态要进 key：key 不变时 ArkUI 会复用节点，样式就停在旧值上（HANDOFF §21.6d）
      `sp-${sec}-${sec >= this.from && sec <= this.to}`)
    }
    .width('100%')
  }
}
