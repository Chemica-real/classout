// 隐私说明页 —— 鸿蒙端 `页脚 → 隐私政策` 那一页（docs/manual/08-privacy.jpg）。
//
// 安卓版之前没有这一页（只有「关于」卡里一句"纯离线"）。上架材料需要它，这里补上。

import 'package:flutter/material.dart';

import '../domain/privacy.dart';
import 'app_frame.dart';
import 'theme.dart';

Future<void> showPrivacyPage(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭隐私说明',
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
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(floatSide),
          child: Glass(
            sheet: true,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('隐私说明',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              color: inkPrimary)),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Icon(Icons.close,
                            size: 18, color: Color(0xFFA9B5C9)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text('更新于 ${privacyUpdatedAt()}',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF8B97AC))),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 18, top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final s in privacySections()) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 14, bottom: 4),
                            child: Text(s.heading,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: inkPrimary)),
                          ),
                          Text(s.body,
                              style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Color(0xFFC3CDDE))),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
