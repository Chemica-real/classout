// 打开 SQLite（FFI）。iOS/Android 上系统自带 libsqlite3，直接开即可；
// Linux 上常见的问题是只有 `libsqlite3.so.0`（没有 dev 包的 `.so` 软链），
// 所以这里显式登记一下库名。

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

bool _overridden = false;

void _ensureOverrides() {
  if (_overridden) return;
  _overridden = true;

  // iOS：sqlite3_flutter_libs 通过 SPM 把 sqlite3 **静态链接**进 Runner。
  // 不要再 dlopen 系统的 'libsqlite3.dylib'（那会同时存在两份，是我们之前
  // App 启动即退出的怀疑来源，见 HANDOFF §48.2）。改用进程内符号。
  if (Platform.isIOS) {
    open.overrideFor(OperatingSystem.iOS, () => DynamicLibrary.process());
  }

  // Android：sqlite3_flutter_libs 会把 libsqlite3.so 打进 App 的 lib 目录，
  // package:sqlite3 的默认加载路径正好找那里，所以**不用**覆盖。
  // （实测：改用系统 /system/lib64/libsqlite3.so 会报
  //  'Failed to lookup symbol sqlite3_libversion_number' —— 系统库不导出完整 API。）

  if (!Platform.isLinux) return;
  open.overrideFor(OperatingSystem.linux, () {
    for (final name in ['libsqlite3.so.0', 'libsqlite3.so']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        // 试下一个
      }
    }
    return DynamicLibrary.process();
  });
}

/// 内存库（测试用）
Database openMemoryDatabase() {
  _ensureOverrides();
  return sqlite3.openInMemory();
}

/// 文件库（App 用）；传入的父目录必须已存在
Database openFileDatabase(String path) {
  _ensureOverrides();
  return sqlite3.open(path);
}

/// 把 schema.sql 拆成一条条语句（去掉 `--` 注释与空段）
List<String> splitSchema(String sql) {
  final out = <String>[];
  for (var chunk in sql.split(';')) {
    final lines =
        chunk.split('\n').where((l) => !l.trimLeft().startsWith('--'));
    final stmt = lines.join('\n').trim();
    if (stmt.isEmpty) continue;
    out.add(stmt);
  }
  return out;
}
