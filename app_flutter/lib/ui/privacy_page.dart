// 隐私说明页 —— 鸿蒙端 `页脚 → 隐私政策` 那一页（docs/manual/08-privacy.jpg）。
//
// 安卓版之前没有这一页（只有「关于」卡里一句"纯离线"）。上架材料需要它，这里补上。

import 'package:flutter/material.dart';

import '../domain/privacy.dart';
import 'theme.dart';

Future<void> showPrivacyPage(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭隐私政策',
    barrierColor: const Color(0x990C1220),
    transitionDuration: dur(durDrawer),
    pageBuilder: (ctx, _, __) => const _PrivacyBody(),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: drawerCurve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
            child: child),
      );
    },
  );
}

class _PrivacyBody extends StatelessWidget {
  const _PrivacyBody();

  @override
  Widget build(BuildContext context) {
    // 鸿蒙 `PrivacyOverlay`：**不透明**深色整屏（政策要逐字读，玻璃在这里只会碍事）
    return Material(
      color: const Color(0xFF0E1420),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('隐私政策',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: inkPrimary)),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 14, top: 4, bottom: 4),
                      child: Text('✕',
                          style: TextStyle(
                              fontSize: 14, color: Color(0xFFA9B5C9))),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('更新日期：${privacyUpdatedAt()}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF8B97AC))),
                      const SizedBox(height: 12),
                      for (final s in privacySections()) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 4),
                          child: Text(s.heading,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: inkPrimary)),
                        ),
                        Text(s.body,
                            style: const TextStyle(
                                fontSize: 12,
                                height: 20 / 12,
                                color: Color(0xFFC3CDDE))),
                      ],
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          height: 40,
                          width: double.infinity,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('关闭',
                              style: TextStyle(
                                  fontSize: 14, color: Color(0xFFC3CDDE))),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
