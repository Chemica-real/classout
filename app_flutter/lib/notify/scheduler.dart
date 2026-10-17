// 把「提醒计划」交给通知系统：先整份撤销，再逐条排。
//
// 每次都是全量重排（不是增量）：本地通知的待发上限只有 64 条，增量排会越积越多、
// 还会留下"课程改了但旧提醒还在"的脏数据。这条规则与鸿蒙端一致。

import '../domain/reminders.dart';
import 'notifier.dart';

class SyncResult {
  final bool granted;
  final int scheduled;
  final int skippedByBudget;
  final int pending;

  const SyncResult({
    required this.granted,
    required this.scheduled,
    required this.skippedByBudget,
    required this.pending,
  });

  @override
  String toString() =>
      'granted=$granted scheduled=$scheduled skipped=$skippedByBudget pending=$pending';
}

/// 把 [plan] 排进系统。`startId` 用于给通知分配稳定的自增 id。
Future<SyncResult> syncNotifications(
  ReminderNotifier notifier,
  ReminderPlanResult plan, {
  int startId = 1000,
}) async {
  final granted = await notifier.ensurePermission();
  await notifier.cancelAll();
  if (!granted) {
    return SyncResult(
        granted: false, scheduled: 0, skippedByBudget: plan.skippedByBudget, pending: 0);
  }
  var id = startId;
  for (final r in plan.published) {
    await notifier.schedule(PlannedNotification(
      id: id++,
      at: r.at,
      title: r.title,
      body: r.content,
      kind: r.kind,
    ));
  }
  return SyncResult(
    granted: true,
    scheduled: plan.published.length,
    skippedByBudget: plan.skippedByBudget,
    pending: await notifier.pendingCount(),
  );
}
