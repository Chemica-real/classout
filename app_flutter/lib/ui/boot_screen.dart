// 启动加载页 —— 鸿蒙端 `pages/Index.ets → LoadingScreen()` + `playBootExit()`。
//
// 结构（与鸿蒙端逐条对应）：
//   ① 极淡网格底纹（横 7 竖 5）
//   ② 两层同心圆环反向自转 + 一圈雷达脉冲（无限循环）
//   ③ ClassOUT 字标（38 粗体、字距 2）+ 渐变细线 + 首页标语（字距 3）
//   ④ 启动清单（5 条真实阶段：✓ 已完成 / ▸ 进行中 / · 未开始）+ 打字机状态 + 5 点点阵
//   ⑤ 就绪过场：停顿 320ms → 整页向内浓缩（2400ms）→ 小白球停留（1360ms）
//                → 白球扩张淡出（1500ms），同时露出应用界面
//
// ⚠️ 装饰动画（圆环/点阵）只在 `ambientMotion` 开着时跑：测试与 golden 里它是 false，
//    否则 pumpAndSettle 永远等不到静止。
// ⚠️ `ready` 变 true 之后才播过场；`onReveal` 在扩张**开始时**调用（应用界面此时挂载），
//    `onDone` 在扩张结束后调用（过场层卸载）。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_frame.dart';
import 'theme.dart';

/// 鸿蒙端 BOOT_STEPS
const List<String> bootSteps = [
  '初始化本地数据',
  '载入课表与节次',
  '补生成下课待办',
  '同步系统日历提醒',
  '就绪',
];

/// 鸿蒙端 SPRAY_R（12 颗粒子的半径，长短交替才像"喷射"）
const List<double> _sprayR = [40, 66, 34, 74, 46, 62, 38, 70, 44, 68, 32, 58];

class BootScreen extends StatefulWidget {
  /// 0..4，见 bootSteps
  final int step;

  /// 首页标语（设置里可改；空 = 不占位）
  final String motto;

  /// 数据都就绪 → 开始播"浓缩成球 → 扩张"
  final bool ready;

  /// 扩张开始（应用界面该挂载了）
  final VoidCallback onReveal;

  /// 过场结束（这一层可以卸载了）
  final VoidCallback onDone;

  const BootScreen({
    super.key,
    required this.step,
    required this.motto,
    required this.ready,
    required this.onReveal,
    required this.onDone,
  });

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> with TickerProviderStateMixin {
  /// 0 加载中 / 1 浓缩 / 2 小球 / 3 扩张
  int _phase = 0;

  late final AnimationController _collapse =
      AnimationController(vsync: this, duration: dur(durCollapse));
  late final AnimationController _expand =
      AnimationController(vsync: this, duration: dur(durExpand));
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 9));
  late final AnimationController _spinBack =
      AnimationController(vsync: this, duration: const Duration(seconds: 16));
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400));
  /// 喷射：每颗粒子 `duration DUR_SPRAY + delay i*46ms`（鸿蒙 `ForEach` 里 `.delay(i * 46)`），
  /// 所以整段时间 = 1100 + 46*11
  late final AnimationController _sprayCtrl = AnimationController(
      vsync: this, duration: dur(durSpray + 46 * (_sprayR.length - 1)));

  /// 打字机状态行
  String _typed = '';

  @override
  void initState() {
    super.initState();
    if (ambientMotion) {
      _spin.repeat();
      _spinBack.repeat();
      _pulse.repeat();
    }
    _type('正在初始化…');
    if (widget.ready) _play();
  }

  @override
  void didUpdateWidget(BootScreen old) {
    super.didUpdateWidget(old);
    if (widget.ready && !old.ready) _play();
    if (widget.step != old.step) _type(_statusFor(widget.step));
  }

  static String _statusFor(int step) {
    switch (step) {
      case 0:
        return '正在初始化…';
      case 1:
        return '正在排课…';
      case 2:
        return '正在补生成下课待办…';
      case 3:
        return '正在重排提醒…';
      default:
        // 鸿蒙端这一步不换文案：打字机那行停在「正在重排提醒…」直到过场结束
        return '正在重排提醒…';
    }
  }

  /// 打字机（每字 [typeMs]，与鸿蒙端一致）
  void _type(String full) {
    _typed = '';
    if (!ambientMotion) {
      // 测试/截图环境：直接给全文，不留定时器
      if (mounted) setState(() => _typed = full);
      return;
    }
    var i = 0;
    Future<void> tick() async {
      while (i <= full.length && mounted) {
        setState(() => _typed = full.substring(0, i));
        i++;
        await Future<void>.delayed(dur(typeMs));
      }
    }

    tick();
  }

  /// 就绪过场（时间线见文件头）
  Future<void> _play() async {
    // 关掉动画（真机设置里）或测试环境（不跑常驻动画）→ 直接进应用
    if (!motionOn || !ambientMotion) {
      widget.onReveal();
      widget.onDone();
      return;
    }
    _type(_statusFor(4));
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    setState(() => _phase = 1);
    await _collapse.forward();
    if (!mounted) return;
    setState(() => _phase = 2);
    _sprayCtrl.forward();
    await Future<void>.delayed(dur(durBallDwell));
    if (!mounted) return;
    widget.onReveal();
    setState(() => _phase = 3);
    await _expand.forward();
    if (!mounted) return;
    widget.onDone();
  }

  @override
  void dispose() {
    _collapse.dispose();
    _expand.dispose();
    _spin.dispose();
    _spinBack.dispose();
    _pulse.dispose();
    _sprayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [_collapse, _expand, _spin, _spinBack, _pulse, _sprayCtrl]),
      builder: (context, _) {
        final collapseT = _collapse.value;
        final expandT = _expand.value;
        return ColoredBox(
          color: pageGradientC,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ①~④ 整页一起浓缩：网格底纹 + 圆环 + 主体（白球/粒子在这层外面）
              Transform.scale(
                scale: _phase >= 2 ? 1 : 1 - 0.94 * collapseT,
                child: Opacity(
                  opacity: _phase >= 2 ? 0 : 1 - collapseT,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                          child: CustomPaint(painter: _GridPainter())),
                      Center(child: _rings()),
                      Center(child: _body()),
                    ],
                  ),
                ),
              ),

              // ⑤ 白球：浓缩时成形，小球停留，然后扩张
              if (_phase >= 1)
                Center(
                  child: Transform.scale(
                    scale: _phase < 3
                        ? (0.2 + 0.8 * collapseT)
                        : (1 + 34 * Curves.easeOutCubic.transform(expandT)),
                    child: Opacity(
                      opacity: _phase < 3 ? 1 : 1 - expandT,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),

              // 喷射粒子（小球停留期间飞出去）
              if (_phase >= 2)
                Center(
                  child: Transform.scale(
                    scale: 1 + 34 * Curves.easeOutCubic.transform(expandT),
                    child: _spray(_sprayCtrl.value),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// ② 两层同心圆环（反向自转）+ 雷达脉冲
  Widget _rings() {
    return SizedBox(
      width: 360,
      height: 360,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.rotate(
            angle: _spin.value * 2 * math.pi,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x4D7FA8FF), width: 1.5),
              ),
            ),
          ),
          Transform.rotate(
            angle: -_spinBack.value * 2 * math.pi,
            child: CustomPaint(
              size: const Size(360, 360),
              painter: _DashedCirclePainter(),
            ),
          ),
          if (ambientMotion)
            Opacity(
              opacity: (1 - _pulse.value) * 0.75,
              child: Container(
                width: 300 * (0.72 + 0.73 * _pulse.value),
                height: 300 * (0.72 + 0.73 * _pulse.value),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x8CB08BE8), width: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    return FractionallySizedBox(
      widthFactor: 0.78,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('ClassOUT',
              style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                  color: inkPrimary)),
          const SizedBox(height: 14),
          Container(
            width: 96,
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: const LinearGradient(colors: [
                Color(0xFF7FA8FF),
                Color(0xFFB08BE8),
                Color(0xFF1F7A73),
              ]),
            ),
          ),
          if (widget.motto.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(widget.motto,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, letterSpacing: 3, color: Color(0xFF8B97AC))),
          ],
          const SizedBox(height: 34),
          Glass(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < bootSteps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        // 用图标而不是 ✓ / ▸：CJK 子集字体里没有这两个字形，
                        // golden 会掉成豆腐块（真机靠系统兜底字体才没露馅）
                        SizedBox(
                          width: 18,
                          child: i < widget.step
                              ? const Icon(Icons.check,
                                  size: 13, color: Color(0xFF7BD69A))
                              : (i == widget.step
                                  ? const Icon(Icons.chevron_right,
                                      size: 15, color: accentBlue)
                                  : const Icon(Icons.circle,
                                      size: 5, color: Color(0xFF5A6478))),
                        ),
                        Text(bootSteps[i],
                            style: TextStyle(
                              fontSize: 12,
                              color: i < widget.step
                                  ? const Color(0xFFA9B5C9)
                                  : (i == widget.step
                                      ? inkPrimary
                                      : const Color(0xFF5A6478)),
                            )),
                        const Spacer(),
                        if (i == widget.step)
                          const Text('进行中',
                              style:
                                  TextStyle(fontSize: 10, color: accentBlue)),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                // 打字机那行
                Text(_typed,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF8B97AC))),
                const SizedBox(height: 18),
                // ⑤ 开局五点（模仿 Ubuntu 开机）
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 5; i++)
                      _Dot(
                        phase: ambientMotion ? _pulse.value : 0.5,
                        index: i,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 12 颗粒子（鸿蒙 `SPRAY_*`）：角度均分、半径查表；大小 `4 + (i%3)*2`、
  /// 白色 + 一圈柔光；每颗粒子延迟 `i*46ms`，用 `DUR_SPRAY` 从"小球还在中心"
  /// 飞散到查询半径，同时放大 0.4→1.35、透明度 1→0（`easeOut`）。
  Widget _spray(double v) {
    const total = durSpray + 46 * 11; // 与控制器时长一致
    return SizedBox(
      width: 160,
      height: 160,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < _sprayR.length; i++)
            Builder(builder: (_) {
              final tp = ((v * total - i * 46) / durSpray).clamp(0.0, 1.0);
              final e = Curves.easeOut.transform(tp);
              return Transform.translate(
                offset: Offset(
                  math.cos(i / _sprayR.length * 2 * math.pi) * _sprayR[i] * e,
                  math.sin(i / _sprayR.length * 2 * math.pi) * _sprayR[i] * e,
                ),
                child: Transform.scale(
                  scale: 0.4 + (1.35 - 0.4) * e,
                  child: Opacity(
                    opacity: 1 - e,
                    child: Container(
                      width: (4 + (i % 3) * 2).toDouble(),
                      height: (4 + (i % 3) * 2).toDouble(),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.85),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// 五个点依次亮起（区间 = 1/6，delay 错开 → 亮点从左跑到右，循环）
class _Dot extends StatelessWidget {
  final double phase;
  final int index;
  const _Dot({required this.phase, required this.index});

  @override
  Widget build(BuildContext context) {
    // 每点相位错开 0.14（与鸿蒙端 delay 140ms / 660ms 的比例一致）
    final p = (phase - index * 0.14) % 1.0;
    final glow = (math.sin(p * math.pi)).clamp(0.0, 1.0);
    return Container(
      width: 9,
      height: 9,
      margin: EdgeInsets.only(right: index < 4 ? 12 : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF7FA8FF)
            .withValues(alpha: ambientMotion ? 0.18 + 0.82 * glow : 0.55),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final hp = Paint()
      ..color = const Color(0x0DFFFFFF)
      ..strokeWidth = 1;
    final vp = Paint()
      ..color = const Color(0x0AFFFFFF)
      ..strokeWidth = 1;
    for (var i = 0; i < 7; i++) {
      final y = 120 + i * 82.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), hp);
    }
    for (var i = 0; i < 5; i++) {
      final x = 60 + i * 92.0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), vp);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

/// 外圈那层虚线圆
class _DashedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x24FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 5.0;
    final r = size.width / 2;
    final circumference = 2 * math.pi * r;
    var a = 0.0;
    while (a < circumference) {
      final sweep = (dash / r);
      canvas.drawArc(
        Rect.fromCircle(center: size.center(Offset.zero), radius: r),
        a / r,
        sweep,
        false,
        paint,
      );
      a += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedCirclePainter old) => false;
}
