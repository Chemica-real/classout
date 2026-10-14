/**
 * 可选中的小胶囊（chip）。
 *
 * ★ 为什么要有这个文件：以前这个控件是**四个几乎一样的 `@Builder` 方法**，
 *   分别写在 TodoInbox / PlanDayView / CourseManager / Index 里，而 `@Builder` 有个坑：
 *
 *   **`@Builder` 的参数是按值传入的，首次渲染后就固化了；参数变化不会让 builder 内部重新渲染。**
 *   于是「点一下让它变蓝」这种效果根本不生效 —— 用户实测报过
 *   （新建待办界面的按钮点了没有任何视觉反应）。
 *
 *   要让 `@Builder` 的参数响应式，得用 `$$` 语法，而 `$$` 只支持值类型，
 *   `onTap: () => void` 这种函数参数**根本没法用**。所以正解是做成真正的自定义组件。
 *
 * `@Prop` 是单向同步：父组件里 `this.editCategory` 变了，这里就会重新渲染。
 * 数据流是显式的，不依赖 ArkUI 对 builder 的隐式优化。
 *
 * 抽成一处还有个额外好处：圆角/内边距/配色只定义一次，
 * 改一次四个界面同时生效（以前改配色要改四个文件，很容易漏）。
 */

@Component
export struct ChipButton {
  /** 胶囊上的文字 */
  @Prop text: string = '';
  /** 是否选中（选中 = 蓝底白字） */
  @Prop selected: boolean = false;
  /** 字号。默认 12；计划页会传它自己的版式字号（见 domain/PlanLayout 的 LAYOUT） */
  @Prop fontSize: number = 12;

  /** 点击回调。放在 @Prop 之外：函数不需要参与响应式 */
  onTap: () => void = (): void => {};

  build() {
    Text(this.text)
      .fontSize(this.fontSize)
      .fontColor(this.selected ? '#FFFFFF' : '#C3CDDE')
      .backgroundColor(this.selected ? '#2E6BE6' : 'rgba(255,255,255,0.14)')
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6, bottom: 6 })
      .onClick((): void => {
        this.onTap();
      })
  }
}
