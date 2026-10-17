// ClassOUT 的设计 token —— **逐条抄自鸿蒙端**，别再自己发挥。
//
// 来源（改这里之前先去那三处看原始注释）：
//   entry/src/main/ets/view/Glass.ets   ← 玻璃态、页面渐变
//   entry/src/main/ets/view/Float.ets   ← 浮窗几何（边距、各栏高度）
//   entry/src/main/ets/view/Motion.ets  ← 时长、曲线、启动过场节奏
//   entry/src/main/ets/model/Types.ets  ← 课程配色 COURSE_COLORS
//
// 用户 2026-10-17：「安卓版与鸿蒙版相差太大，希望几乎完全仿照」。
// 所以这个文件是**唯一允许写死数值的地方**，页面里不要再出现魔法数字。

import 'package:flutter/material.dart';

// ============================ 一、颜色 ============================

/// 页面背景渐变（0 / 0.5 / 1 三个色标）
const Color pageGradientA = Color(0xFF0F0C29); // 顶部 深蓝黑
const Color pageGradientB = Color(0xFF302B63); // 中部 深紫蓝
const Color pageGradientC = Color(0xFF24243E); // 底部 深紫

const LinearGradient pageGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [pageGradientA, pageGradientB, pageGradientC],
  stops: [0.0, 0.5, 1.0],
);

/// 文字三级 + 两个语义色
const Color inkPrimary = Color(0xFFF2F5FA);
const Color inkSecondary = Color(0xFF9BA7BD);
const Color inkTertiary = Color(0xFF8B97AC);
const Color accentBlue = Color(0xFF7FA8FF);
const Color goodGreen = Color(0xFF8FC9A0);
const Color dangerRed = Color(0xFFFF8080);

/// 课程配色（深底 + 白字），与鸿蒙端 COURSE_COLORS 逐项一致
const List<Color> courseColors = <Color>[
  Color(0xFF8A6B1F), // 黄（深金）
  Color(0xFF2F7D4F), // 绿
  Color(0xFF2C5FA8), // 蓝
  Color(0xFF6B45A8), // 紫
  Color(0xFF1F7A73), // 青
  Color(0xFFA8452F), // 珊瑚
  Color(0xFF8A3D6B), // 粉（品红）
  Color(0xFF4A5B75), // 灰蓝
  Color(0xFF7A6A2F), // 卡其
  Color(0xFF4F7A2F), // 草绿
];

Color courseColor(int i) => courseColors[i % courseColors.length];

/// 常驻环境动画（背景光晕漂移）的总开关。
/// 测试里由 `test/flutter_test_config.dart` 关掉 —— 无限循环的动画会让 pumpAndSettle 永远不"静止"。
bool ambientMotion = motionOn;

/// 背景装饰光晕（鸿蒙端 Glass.ets：两个大圆 + blur，让纯渐变有结构可透）
const Color glowPink = Color(0xFFFF6FD8);
const double glowPinkBlur = 80;
const double glowPinkOpacity = 0.35;
const Color glowCyan = Color(0xFF00D4FF);
const double glowCyanBlur = 60;
const double glowCyanOpacity = 0.25;

// ============================ 二、玻璃态 ============================

/// backdropBlur 的 sigma（鸿蒙端 GLASS_BLUR = 20）
const double glassBlur = 20;

/// 卡片 / 抽屉 / 行 三种底色
const Color glassTintPanel = Color(0x29FFFFFF); // rgba(255,255,255,0.16)
const Color glassTintSheet = Color(0x2EFFFFFF); // rgba(255,255,255,0.18)
const Color glassTintRow = Color(0x1AFFFFFF); // rgba(255,255,255,0.10)

/// 描边：强（卡片）/ 软（行）
const Color glassEdgeStrong = Color(0x40FFFFFF); // rgba(255,255,255,0.25)
const Color glassEdgeSoft = Color(0x24FFFFFF); // rgba(255,255,255,0.14)

/// 底板（待安排托盘那种更暗的）
const Color glassTintShelf = Color(0x6B0A0E1A); // rgba(10,14,26,0.42)
const Color glassEdgeShelf = Color(0x2EFFFFFF); // rgba(255,255,255,0.18)

const double glassRadius = 20;
const double glassRadiusShelf = 16;

const List<BoxShadow> glassShadowRow = [
  BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6)),
];
const List<BoxShadow> glassShadowSheet = [
  BoxShadow(color: Color(0x6B000000), blurRadius: 26, offset: Offset(0, 10)),
];
const List<BoxShadow> glassShadowShelf = [
  BoxShadow(color: Color(0x4D000000), blurRadius: 12, offset: Offset(0, 4)),
];

// ============================ 三、浮窗几何 ============================

/// 悬浮栏左右与下方留白、顶部留白
const double floatSide = 10;
const double floatGap = 10;
const double floatTop = 8;

/// 各栏高度（鸿蒙端同名常量的数值）
const double hHeader = 78; // 课表页头那一条
const double hTabbar = 54; // 底部导航
const double hWeekRow = 38; // 星期表头
const double hDayBar = 46;
const double hColHead = 34;
const double hActions = 44;
const double hTitle = 44;

/// 抽屉宽度占屏比
const double drawerWidthFactor = 0.84;

// ============================ 四、动效 ============================

const int durTab = 200;
const int durDrawer = 300;
const int durTray = 260;
const int durItem = 240;
const int durShard = 320;
const int durHint = 200;
const int durCollapse = 2400; // 就绪过场：整页向内浓缩
const int durBallDwell = 1360; // 小球停留
const int durExpand = 1500; // 白球扩张到全屏
const int durSpray = 1100; //
const int typeMs = 45; // 打字机每个字
const int bootStepMs = 380; // 启动步骤之间
const int bootExtraCapMs = 1900;

/// 通用"鸿蒙手感"：springMotion(0.34, 0.9)。
/// Flutter 没有现成的同名曲线，用轻度过冲的 easeOutBack 近似（观感最接近）。
const Curve motionCurve = Curves.easeOutBack;

/// 就绪过场：向内浓缩（必须贝塞尔，弹簧会忽略 duration）
const Curve collapseCurve = Cubic(0.33, 0.0, 0.20, 1.0);

/// 白球扩张（y2 = 1.10 → 约 10% 过冲，就是"Q 弹"）
const Curve expandCurve = Cubic(0.22, 0.0, 0.32, 1.10);

/// 抽屉：响应更快、收尾更紧
const Curve drawerCurve = Curves.easeOutCubic;

/// 动效总开关（对应鸿蒙端 kv `motionOn`）
bool motionOn = true;

/// 时长：关掉动画时返回 0，所有 animateTo/transition 退化为瞬切
Duration dur(int ms) => Duration(milliseconds: motionOn ? ms : 0);

/// 曲线：关掉动画时给线性
Curve curveOr(Curve c) => motionOn ? c : Curves.linear;

// ============================ 五、文字 ============================

/// 页头标题（学期名 / 页面名）
const TextStyle textHeaderTitle = TextStyle(
    fontSize: 22, fontWeight: FontWeight.w700, color: inkPrimary, height: 1.15);

/// 卡片小标题
const TextStyle textSectionTitle =
    TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: inkPrimary);

/// 正文
const TextStyle textBody = TextStyle(fontSize: 13, color: inkPrimary);

/// 次要说明
const TextStyle textHint = TextStyle(fontSize: 11, color: inkTertiary);

/// 行内次要信息
const TextStyle textSub = TextStyle(fontSize: 12, color: inkSecondary);

/// 解析壁纸的 'dx,dy,zoom'（对应鸿蒙端 `parseWallpaperFocus`）：
/// 坏值一律回 (0,0,1)；zoom 夹在 1..3。
({double dx, double dy, double zoom}) parseWallpaperFocus(String raw) {
  final parts = raw.split(',');
  if (parts.length != 3) return (dx: 0, dy: 0, zoom: 1);
  final dx = double.tryParse(parts[0].trim()) ?? 0;
  final dy = double.tryParse(parts[1].trim()) ?? 0;
  final z = double.tryParse(parts[2].trim()) ?? 1;
  return (
    dx: dx.clamp(-1.0, 1.0),
    dy: dy.clamp(-1.0, 1.0),
    zoom: z.clamp(1.0, 3.0),
  );
}

String formatWallpaperFocus(double dx, double dy, double zoom) =>
    '${dx.toStringAsFixed(3)},${dy.toStringAsFixed(3)},${zoom.toStringAsFixed(3)}';
