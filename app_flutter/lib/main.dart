// ClassOUT（iOS / Android）—— UI 还没开始写，这里先放一个占位壳，
// 让 `flutter run -d web-server` / `flutter build ios` 有东西可跑。
//
// 已完成的规则层在 lib/domain/：plan_math / validate / sync_cadence，
// 与鸿蒙端的一致性由 test/fixtures_test.dart 守（353 条 fixture）。
import 'package:flutter/material.dart';

void main() => runApp(const ClassOutApp());

class ClassOutApp extends StatelessWidget {
  const ClassOutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClassOUT',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7FA8FF),
        useMaterial3: true,
      ),
      home: const _Placeholder(),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text('ClassOUT', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
            SizedBox(height: 10),
            Text('iOS / Android 版（UI 待实现）'),
            SizedBox(height: 6),
            Text('规则层已与鸿蒙端对齐：353 条 fixture 全绿',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
          ],
        ),
      ),
    );
  }
}
