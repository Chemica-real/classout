// 「导入备份」对话框：粘贴 ClassOUT 导出的 JSON → 校验 → 返回解析好的 bundle。
//
// 为什么先做"粘贴"而不是"选文件"：
//   粘贴这条路**三端都能用、也能被自动化测试覆盖**；选文件要接 file_picker 插件，
//   在这台 Linux 上没法验证真机行为。选文件是下一步。

import 'package:flutter/material.dart';

import '../data/backup.dart';
import 'backup_picker.dart';
import 'palette.dart';

/// 返回解析好的备份；用户取消返回 null。解析失败会在对话框里显示原因，不关窗。
///
/// [picker] 可以注入（测试用假实现）；默认走 file_picker：
/// iPad/iPhone 上从「文件」选中导出的 .json，浏览器上弹系统文件选择框。
Future<BackupBundle?> showImportDialog(BuildContext context,
    {String? hint, BackupPicker? picker}) {
  return showDialog<BackupBundle>(
    context: context,
    builder: (ctx) => _ImportDialog(
      hint: hint,
      picker: picker ?? const FilePickerBackupPicker(),
    ),
  );
}

class _ImportDialog extends StatefulWidget {
  final String? hint;
  final BackupPicker picker;
  const _ImportDialog({this.hint, required this.picker});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _picking = false;

  /// 选文件 → 把内容填进输入框（让用户看清读到了什么，再点「导入」确认）
  Future<void> _pickFile() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final text = await widget.picker.pickBackupText();
      if (!mounted) return;
      if (text == null) {
        setState(() => _picking = false); // 用户取消
        return;
      }
      _ctrl.text = text;
      setState(() {
        _picking = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = '读取文件失败：$e';
      });
    }
  }

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
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('pick-file'),
                  onPressed: _picking ? null : _pickFile,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text(_picking ? '读取中…' : '选择文件…',
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('或者直接把 JSON 粘在下面',
                      style: TextStyle(fontSize: 11, color: inkTertiary)),
                ),
              ],
            ),
            const SizedBox(height: 8),
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
