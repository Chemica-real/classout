// 「从文件选择备份」这条路。
//
// 为什么要抽象一层：file_picker 是平台插件，测试环境里没有它的通道实现。
// 抽成接口之后：
//   - 真实实现（FilePickerBackupPicker）在 iPad/iPhone/Android/浏览器上都能用；
//   - 测试注入假实现，把"选文件 → 填进输入框 → 导入"这条链路完整测掉。
//
// 为什么优先给「选文件」而不是只让用户粘贴：iPad/iPhone 上从「文件」里选一个 JSON
// 很自然；把几万字的 JSON 粘进多行输入框基本没法用。

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;

abstract class BackupPicker {
  /// 让用户选一个备份文件；返回文件内容（UTF-8 文本）。
  /// 用户取消 → null；读失败 → 抛异常给调用方提示。
  Future<String?> pickBackupText();
}

class FilePickerBackupPicker implements BackupPicker {
  const FilePickerBackupPicker();

  @override
  Future<String?> pickBackupText() async {
    // ⚠️ file_picker 13 的 API 和网上大多数示例（`FilePicker.platform.pickFiles(...)`）
    //    不一样：这里是**静态方法**，返回 `List<PlatformFile>`（取消 = 空列表），
    //    也没有 `withData` 参数 —— 字节要用 `PlatformFile.readAsBytes()` 读。
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: '选择 ClassOUT 备份（.json）',
    );
    if (files.isEmpty) return null; // 用户取消
    final bytes = await files.first.readAsBytes();
    // 备份是纯 UTF-8 JSON（见 shared/backup-v1.md）
    final text = utf8.decode(bytes);
    debugPrint('[ClassOUT] pick: ${files.first.name} → ${bytes.length} 字节');
    return text;
  }
}
