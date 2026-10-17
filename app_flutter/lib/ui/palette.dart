import 'package:flutter/material.dart';

/// 课程配色 —— 与鸿蒙端 model/Types.ets 的 COURSE_COLORS 一致（深底 + 白字）。
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

Color courseColor(int colorIndex) =>
    courseColors[colorIndex % courseColors.length];

// 与鸿蒙端一致的几处基础色
const Color inkPrimary = Color(0xFFF2F5FA);
const Color inkSecondary = Color(0xFF9BA7BD);
const Color inkTertiary = Color(0xFF8B97AC);
const Color accentBlue = Color(0xFF7FA8FF);
const Color goodGreen = Color(0xFF8FC9A0);
