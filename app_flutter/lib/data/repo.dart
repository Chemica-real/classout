// 数据仓库的抽象：UI 只认这个接口，这样「内存版（web / 演示）」和
// 「SQLite 版（iOS/Android）」可以互换，测试也能拿两份实现互相对照。

import 'backup.dart';

abstract class ClassOutRepo {
  /// 读出全部数据（空库返回 null）
  Future<BackupBundle?> load();

  /// 导入 = **整份替换**（见 shared/backup-v1.md 的导入规则第 1 条）
  Future<void> replaceAll(BackupBundle bundle);

  Future<void> close();
}

/// 内存实现：给 web 预览和测试用；重启即丢（演示版行为）
class MemoryRepo implements ClassOutRepo {
  BackupBundle? _data;

  MemoryRepo([this._data]);

  @override
  Future<BackupBundle?> load() async => _data;

  @override
  Future<void> replaceAll(BackupBundle bundle) async {
    _data = bundle;
  }

  @override
  Future<void> close() async {}
}
