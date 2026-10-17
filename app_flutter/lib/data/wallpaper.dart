// 自定义壁纸（鸿蒙端 `data/WallpaperRepo.ets` 的简化版）。
//
// 鸿蒙端把照片**复制进 App 私有目录**再记路径（不联网、不需要相册权限）。
// 这里同样：file_picker 拿到临时路径 → 复制到 ApplicationSupport 目录 → kv 里存新路径。
// 解码失败/文件丢了 → 设置页显示"默认渐变"，AppFrame 也自动退回渐变（不闪黑）。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 选一张图并复制进 App 目录，返回新路径；用户取消 → null
Future<String?> pickAndSaveWallpaper() async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  if (files.isEmpty) return null;
  final src = files.first.path;
  if (src == null) return null;
  final dir = await getApplicationSupportDirectory();
  final name = src.split(RegExp(r'[/\\]')).last;
  final ext =
      name.contains('.') ? name.substring(name.lastIndexOf('.')) : '.jpg';
  final target = File('${dir.path}${Platform.pathSeparator}wallpaper$ext');
  await File(src).copy(target.path);
  return target.path;
}

/// 恢复默认背景：删掉复制进来的那份（失败也无所谓）
Future<void> clearWallpaper(String path) async {
  if (path.isEmpty) return;
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // 删不掉不影响使用：kv 里已经不再引用它
  }
}

/// 壁纸文件是否真的存在（决定要不要画图）
bool wallpaperExists(String path) {
  if (path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}
