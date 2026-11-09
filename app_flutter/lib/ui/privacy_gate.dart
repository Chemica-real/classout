// 首启隐私同意门。
//
// 鸿蒙端 `Index.ets` 的 PrivacyGateCard：同意之前不进入业务、不建业务数据。
// Android 这里把门放在 `_Boot` **之前**，同意前连仓库都不打开；同意标记直接用
// 应用文档目录里的一个小文本文件，避免为了读一个标记就初始化 SQLite。
//
// 测试/预览可以注入 `isAccepted` / `accept`，默认走真实文件。

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/privacy.dart';
import 'palette.dart' show pageGradientC, inkPrimary, inkSecondary, inkTertiary;

const String privacyAgreementFile = 'privacy-agreed.txt';

Future<String> _agreementPath() async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}${Platform.pathSeparator}$privacyAgreementFile';
}

class PrivacyGate extends StatefulWidget {
  final Widget child;
  final Future<bool> Function()? isAccepted;
  final Future<void> Function()? accept;

  const PrivacyGate({
    super.key,
    required this.child,
    this.isAccepted,
    this.accept,
  });

  @override
  State<PrivacyGate> createState() => _PrivacyGateState();
}

class _PrivacyGateState extends State<PrivacyGate> {
  bool? _accepted;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (widget.isAccepted != null) {
      final v = await widget.isAccepted!();
      if (mounted) setState(() => _accepted = v);
      return;
    }
    if (kIsWeb) {
      if (mounted) setState(() => _accepted = true);
      return;
    }
    try {
      final f = File(await _agreementPath());
      final v = await f.exists() ? (await f.readAsString()).trim() : '';
      if (mounted) setState(() => _accepted = v == privacyUpdatedAt());
    } catch (_) {
      if (mounted) setState(() => _accepted = false);
    }
  }

  Future<void> _agree() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (widget.accept != null) {
        await widget.accept!();
      } else if (!kIsWeb) {
        await File(await _agreementPath()).writeAsString(privacyUpdatedAt());
      }
      if (mounted) setState(() => _accepted = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _refuse() {
    // 鸿蒙 `terminateSelf()`；Android 用系统返回栈退出。
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted == null) {
      return const Scaffold(
        backgroundColor: pageGradientC,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_accepted!) return widget.child;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: pageGradientC,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('隐私政策',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: inkPrimary)),
                const SizedBox(height: 4),
                Text('更新日期：${privacyUpdatedAt()}',
                    style: const TextStyle(
                        fontSize: 11, color: inkTertiary)),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: const Color(0xD90E1420),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0x2EFFFFFF)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ClassOUT 完全离线运行。在开始使用前，请阅读并同意下面的隐私说明。',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: inkSecondary),
                          ),
                          for (final s in privacySections()) ...[
                            const SizedBox(height: 12),
                            Text(s.heading,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: inkPrimary)),
                            const SizedBox(height: 3),
                            Text(s.body,
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    height: 1.55,
                                    color: inkSecondary)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E6BE6),
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _saving ? null : _agree,
                    child: Text(_saving ? '正在保存…' : '同意并继续',
                        style: const TextStyle(fontSize: 15)),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _refuse,
                    child: const Text('不同意并退出',
                        style: TextStyle(fontSize: 12, color: inkTertiary)),
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
