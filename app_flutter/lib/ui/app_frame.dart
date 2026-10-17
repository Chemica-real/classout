// 应用外壳：页面背景渐变 + 底部四标签 + 共用 Glass 底板。
//
// 数值全部来自 theme.dart（= 鸿蒙端 Glass.ets / Float.ets 的原始值）：
//   渐变 #0f0c29→#302b63→#24243e，blur 20，圆角 20，白 0.16，描边 0.25/0.14。

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'theme.dart';

const List<String> tabLabels = ['课表', '待办', '计划', '设置'];

/// 内容底部要给「悬浮导航栏 + 上下两条缝」让出的高度（鸿蒙端 bottomInset + FLOAT_GAP）
const double tabBarInset = floatGap + hTabbar + floatGap;

class AppFrame extends StatefulWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final Widget child;

  /// 自定义壁纸（空 = 默认渐变）。对应鸿蒙端 PageBackground 的 `wallpaper`
  final String wallpaperPath;

  const AppFrame({
    super.key,
    required this.tab,
    required this.onTab,
    required this.child,
    this.wallpaperPath = '',
  });

  @override
  State<AppFrame> createState() => _AppFrameState();
}

class _AppFrameState extends State<AppFrame>
    with SingleTickerProviderStateMixin {
  /// 光晕漂移（鸿蒙端：Alternate + 无限，只动 translate/opacity；这里是 9 秒一来一回）
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void initState() {
    super.initState();
    if (motionOn && ambientMotion) _orbit.repeat(reverse: true);
  }

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: pageGradient),
      child: ClipRect(
        child: Stack(
          children: [
            // 自定义壁纸：铺满 + 压暗薄纱（照片明暗不可控，正文还得压在上面）
            if (widget.wallpaperPath.isNotEmpty &&
                File(widget.wallpaperPath).existsSync())
              Positioned.fill(
                child: Image.file(
                  File(widget.wallpaperPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            if (widget.wallpaperPath.isNotEmpty &&
                File(widget.wallpaperPath).existsSync())
              const Positioned.fill(
                child:
                    ColoredBox(color: Color(0x9E060810)), // rgba(6,8,16,0.62)
              ),
            // 两个装饰光晕：**只在没有自定义壁纸时**画。鸿蒙端的 PageBackground 把光晕放在
            // 照片**之下**，设了照片就看不见了 —— 我们之前把光晕画在照片之上，
            // 结果安卓端壁纸整体偏粉/偏亮（双机对比一眼可见）。
            if (!(widget.wallpaperPath.isNotEmpty &&
                File(widget.wallpaperPath).existsSync()))
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _orbit,
                  builder: (context, _) {
                    final t = _orbit.value;
                    return Stack(
                      children: [
                        Positioned(
                          top: 60 - 0 + 64 * t,
                          right: -40 + 46 * t,
                          child: _Glow(
                            size: 280,
                            color: glowPink,
                            opacity: glowPinkOpacity * (1 - 0.35 * t),
                            blur: glowPinkBlur,
                          ),
                        ),
                        Positioned(
                          bottom: 100 - 48 * t,
                          left: -30 + 54 * t,
                          child: _Glow(
                            size: 200,
                            color: glowCyan,
                            opacity: glowCyanOpacity * (1 + 0.25 * t),
                            blur: glowCyanBlur,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            SafeArea(
              // 底部导航栏是**悬浮浮窗**（鸿蒙端 TabBar 也是浮在内容之上）：
              // 内容铺满整屏、从它下面滑过，靠 tabBarInset 给底部留白。
              child: Stack(
                children: [
                  Positioned.fill(child: widget.child),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomTabs(tab: widget.tab, onTab: widget.onTab),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个模糊大圆（鸿蒙端：Column + borderRadius + backgroundColor + blur）
class _Glow extends StatelessWidget {
  final double size;
  final Color color;
  final double opacity;
  final double blur;
  const _Glow({
    required this.size,
    required this.color,
    required this.opacity,
    required this.blur,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur / 2, sigmaY: blur / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _BottomTabs extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _BottomTabs({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(floatSide, 4, floatSide, floatGap),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(glassRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
          child: Container(
            // 鸿蒙端 H_TABBAR = 54
            height: hTabbar,
            decoration: BoxDecoration(
              color: glassTintPanel,
              borderRadius: BorderRadius.circular(glassRadius),
              border: Border.all(color: glassEdgeStrong),
              boxShadow: glassShadowRow,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(tabLabels.length, (i) {
                final active = i == tab;
                return InkWell(
                  onTap: () => onTab(i),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Text(
                      tabLabels[i],
                      style: TextStyle(
                        fontSize: 13,
                        // 鸿蒙端：两边都是**加粗白字**，选中态靠不透明度区分
                        fontWeight: FontWeight.bold,
                        color: active
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xB8FFFFFF),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一的玻璃底板（对应鸿蒙端 `.glassPanelCard()` / `.glassSheet()`）
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;

  /// sheet = 抽屉/弹窗（更亮的底色 + 更重的阴影），panel = 普通卡片
  final bool sheet;
  final double radius;

  const Glass({
    super.key,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.padding = const EdgeInsets.all(12),
    this.sheet = false,
    this.radius = glassRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: sheet ? glassTintSheet : glassTintPanel,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: glassEdgeStrong),
              boxShadow: sheet ? glassShadowSheet : glassShadowRow,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 更暗的托盘底板（待安排货架那种）
class GlassShelf extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;
  const GlassShelf({
    super.key,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.padding = const EdgeInsets.all(10),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(glassRadiusShelf),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glassBlur, sigmaY: glassBlur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: glassTintShelf,
              borderRadius: BorderRadius.circular(glassRadiusShelf),
              border: Border.all(color: glassEdgeShelf),
              boxShadow: glassShadowShelf,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 量出子树的尺寸（页头这种"高度会变、又必须让内容留出同样高度"的浮窗用它）
class MeasureSize extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onSize;
  const MeasureSize({super.key, required this.child, required this.onSize});

  @override
  State<MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<MeasureSize> {
  @override
  void initState() {
    super.initState();
    // ⚠️ 首帧**不会有** SizeChangedLayoutNotification（尺寸从"无"到"有"不算变更），
    // 所以这里主动量一次，否则第一次布局会按估算值留白、内容和浮窗叠在一起。
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    final s = context.size;
    if (s != null && mounted) widget.onSize(s);
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (n) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _report());
        return true;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}
