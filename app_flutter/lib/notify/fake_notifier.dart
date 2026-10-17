import 'notifier.dart';

/// 测试替身：只记录调用，不碰系统
class FakeNotifier implements ReminderNotifier {
  final List<PlannedNotification> scheduled = [];
  int cancelAllCalls = 0;
  bool permissionGranted;
  int? pendingCountOverride;

  FakeNotifier({this.permissionGranted = true, this.pendingCountOverride});

  @override
  Future<bool> ensurePermission() async => permissionGranted;

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    scheduled.clear();
  }

  @override
  Future<void> schedule(PlannedNotification n) async => scheduled.add(n);

  @override
  Future<int> pendingCount() async => pendingCountOverride ?? scheduled.length;
}
