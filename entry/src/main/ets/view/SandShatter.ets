/**
 * 删除时的「沙粒碎裂」。
 *
 * 用户 2026-11-01 要的动画：几何图形**自上而下**碎成细沙，沙粒自由落体到屏幕外；
 * 待办页下方的条目同时平滑上移。这个组件只负责画沙粒，删除时机由宿主控制。
 *
 * 用固定数量的 2–5vp 小方块模拟细沙：不依赖 Canvas/位图，低端机也能跑；
 * 每颗粒子的起始位置、横向漂移、下落距离、旋转和延迟都由确定性的伪随机数生成。
 * 动画总开关关闭时宿主**根本不会挂这个组件**，所以这里只负责"开"的路径。
 */

interface SandParticle {
  x: number;
  y: number;
  size: number;
  dx: number;
  dy: number;
  rot: number;
  delay: number;
  dur: number;
  tone: number;
}

const COLORS: string[] = ['rgba(255,255,255,0.82)', 'rgba(203,214,232,0.86)',
  'rgba(127,168,255,0.82)', 'rgba(255,214,140,0.78)'];

/** 简单的确定性伪随机：同一个位置每次重绘不会跳来跳去 */
function rand(seed: number): number {
  const x: number = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
}

function makeParticles(): SandParticle[] {
  const out: SandParticle[] = [];
  for (let i = 0; i < 72; i++) {
    const x: number = rand(i + 1);
    const y: number = rand(i + 101);
    out.push({
      x: x,
      y: y,
      size: 2 + Math.round(rand(i + 201) * 3),
      dx: (rand(i + 301) - 0.5) * 46,
      dy: -10 + Math.round(rand(i + 401) * 34),
      rot: (rand(i + 501) - 0.5) * 220,
      // 顶部先碎、底部后碎：从上往下 0–150ms 的错峰
      delay: Math.round(y * 150),
      dur: 520 + Math.round(rand(i + 601) * 220),
      tone: i % COLORS.length
    });
  }
  return out;
}

const PARTICLES: SandParticle[] = makeParticles();

@Component
export struct SandShatter {
  /** 碎片里混一点主题色，让"这块的碎片"和背景区分开 */
  @Prop tint: string = '#7FA8FF';
  @State private started: boolean = false;
  @State private w: number = 100;
  @State private h: number = 100;

  aboutToAppear(): void {
    // 等一帧拿到真实宽高，再开始下落
    setTimeout((): void => {
      this.started = true;
    }, 50);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(PARTICLES, (p: SandParticle, i: number) => {
        Column()
          .width(p.size)
          .height(p.size)
          .borderRadius(1)
          .backgroundColor(p.tone === 2 ? this.tint : COLORS[p.tone])
          .position({ x: p.x * this.w, y: p.y * this.h })
          .translate({
            x: this.started ? p.dx : 0,
            y: this.started ? (this.h + 620 - p.y * this.h + p.dy) : 0
          })
          .rotate({ angle: this.started ? p.rot : 0 })
          .scale({ x: this.started ? 0.25 : 1, y: this.started ? 0.25 : 1 })
          .opacity(this.started ? 0 : 1)
          .animation({
            duration: p.dur,
            delay: p.delay,
            curve: Curve.EaseIn
          })
          .hitTestBehavior(HitTestMode.None)
      }, (p: SandParticle, i: number) => `sand-${i}-${p.x}-${p.y}`)
    }
    .width('100%')
    .height('100%')
    .clip(false)
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const w: Length | undefined = newArea.width;
      const h: Length | undefined = newArea.height;
      if (typeof w === 'number' && w > 0) {
        this.w = w;
      }
      if (typeof h === 'number' && h > 0) {
        this.h = h;
      }
    })
  }
}
