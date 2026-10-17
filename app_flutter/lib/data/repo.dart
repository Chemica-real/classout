// 数据仓库的抽象：UI 只认这个接口，这样「内存版（web / 演示）」和
// 「SQLite 版（iOS/Android）」可以互换，测试也能拿两份实现互相对照。

import 'backup.dart';

abstract class ClassOutRepo {
  /// 读出全部数据（空库返回 null）
  Future<BackupBundle?> load();

  /// 导入 = **整份替换**（见 shared/backup-v1.md 的导入规则第 1 条）
  Future<void> replaceAll(BackupBundle bundle);

  Future<void> close();

  /// 设置项（对应鸿蒙端的 kv 表）
  Future<String?> getKv(String key);
  Future<void> setKv(String key, String value);

  /// 删掉一个设置项（演练沙箱进出时用：沙箱里新写的键要能整份撤掉）
  Future<void> removeKv(String key);

  /// 整张 kv 表（演练沙箱进沙箱前"整份记住偏好"用）
  Future<Map<String, String>> dumpKv();
}

/// 内存实现：给 web 预览和测试用；重启即丢（演示版行为）
class MemoryRepo implements ClassOutRepo {
  BackupBundle? _data;
  final Map<String, String> _kv = {};

  MemoryRepo([this._data]);

  @override
  Future<BackupBundle?> load() async => _data;

  @override
  Future<void> replaceAll(BackupBundle bundle) async {
    _data = bundle;
  }

  @override
  Future<void> close() async {}

  @override
  Future<String?> getKv(String key) async => _kv[key];

  @override
  Future<void> setKv(String key, String value) async {
    _kv[key] = value;
  }

  @override
  Future<void> removeKv(String key) async {
    _kv.remove(key);
  }

  @override
  Future<Map<String, String>> dumpKv() async => Map<String, String>.from(_kv);
}
