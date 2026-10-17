// 打开 SQLite（FFI）。iOS/Android 上系统自带 libsqlite3，直接开即可；
// Linux 上常见的问题是只有 `libsqlite3.so.0`（没有 dev 包的 `.so` 软链），
// 所以这里显式登记一下库名。

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

bool _overridden = false;

void _ensureLinuxOverride() {
  if (_overridden) return;
  _overridden = true;
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
  _ensureLinuxOverride();
  return sqlite3.openInMemory();
}

/// 文件库（App 用）；传入的父目录必须已存在
Database openFileDatabase(String path) {
  _ensureLinuxOverride();
  return sqlite3.open(path);
}

/// 把 schema.sql 拆成一条条语句（去掉 `--` 注释与空段）
List<String> splitSchema(String sql) {
  final out = <String>[];
  for (var chunk in sql.split(';')) {
    final lines = chunk.split('\n').where((l) => !l.trimLeft().startsWith('--'));
    final stmt = lines.join('\n').trim();
    if (stmt.isEmpty) continue;
    out.add(stmt);
  }
  return out;
}
