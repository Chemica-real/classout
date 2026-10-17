// 自动生成待办的**黑名单** —— 鸿蒙端 `todo_blacklist` 表（`TodoRepo.blacklist` /
// `isBlacklisted`）的安卓版。
//
// 背景：模板在「下课」时会自动生成待办；用户如果明确删掉了其中一条，
// 下次补生成不应该把它又生成回来。鸿蒙用一张表记住 `generation_key`，
// 安卓这边数据层是"整份 bundle"，所以把同样的键集合存进 kv（JSON 数组）。
//
// 与鸿蒙一致的规则：
//   · 只有**自动生成**的（`generationKey` 非空）才记；
//   · 导入备份 = 整份覆盖，黑名单一起清空（鸿蒙 `BackupRepo.restore` 也是 DELETE 这张表）；
//   · 演练沙箱里不串：进沙箱时清掉、退出时由 `sandbox_prefs` 快照整份还原。

import 'dart:convert';

import 'repo.dart';

/// kv 键名（与鸿蒙表名同义）
const String todoBlacklistKv = 'todo_blacklist';

/// 解析 kv 里的 JSON；坏数据当作空集合（不抛）
Set<String> blacklistFromRaw(String raw) {
  if (raw.isEmpty) return <String>{};
  try {
    final v = jsonDecode(raw);
    if (v is List) {
      return <String>{for (final e in v) '$e'.trim()}
        ..removeWhere((e) => e.isEmpty);
    }
  } catch (_) {
    // 损坏的 kv：当成空
  }
  return <String>{};
}

String blacklistToRaw(Set<String> keys) =>
    jsonEncode((keys.toList()..sort()));

Future<Set<String>> loadBlacklist(ClassOutRepo repo) async =>
    blacklistFromRaw(await repo.getKv(todoBlacklistKv) ?? '');

/// 把若干个键并进黑名单（返回合并后的集合）
Future<Set<String>> addToBlacklist(ClassOutRepo repo, Iterable<String> keys) async {
  final want = keys.where((k) => k.isNotEmpty).toSet();
  final cur = await loadBlacklist(repo);
  if (want.isEmpty) return cur;
  final next = {...cur, ...want};
  if (next.length != cur.length) {
    await repo.setKv(todoBlacklistKv, blacklistToRaw(next));
  }
  return next;
}
