// 所有测试的公共启动钩子：关掉**常驻**动画。
//
// 背景光晕是无限循环（repeat reverse），只要它开着，pumpAndSettle 就永远等不到"静止"，
// 每个 widget 测试都会超时。截图（goldens）也需要确定性，所以统一在测试里关掉它。
import 'dart:async';

import 'package:classout/ui/theme.dart' as theme;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  theme.ambientMotion = false;
  await testMain();
}
