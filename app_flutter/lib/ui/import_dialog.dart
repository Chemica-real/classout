// 「导入备份」对话框：粘贴 ClassOUT 导出的 JSON → 校验 → 返回解析好的 bundle。
//
// 为什么先做"粘贴"而不是"选文件"：
//   粘贴这条路**三端都能用、也能被自动化测试覆盖**；选文件要接 file_picker 插件，
//   在这台 Linux 上没法验证真机行为。选文件是下一步。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import 'palette.dart';

/// 返回解析好的备份；用户取消返回 null。解析失败会在对话框里显示原因，不关窗。
Future<BackupBundle?> showImportDialog(BuildContext context, {String? hint}) {
  return showDialog<BackupBundle>(
    context: context,
    builder: (ctx) => _ImportDialog(hint: hint),
  );
}

class _ImportDialog extends StatefulWidget {
  final String? hint;
  const _ImportDialog({this.hint});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '先粘贴备份 JSON');
      return;
    }
    try {
      final bundle = BackupBundle.decode(text);
      if (bundle.semester == null) {
        setState(() => _error = '这份备份里没有学期数据');
        return;
      }
      Navigator.of(context).pop(bundle);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '解析失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入备份'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.hint ??
                  '把 ClassOUT 导出的备份 JSON 粘进来。\n'
                      '鸿蒙端：「管理课程 → 备份与恢复 → 导出备份」。',
              style: const TextStyle(fontSize: 12, color: inkSecondary),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              maxLines: 6,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: '{"app":"ClassOUT","version":1,…}',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFFF8080))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}
