// 通知的抽象：排期逻辑只依赖这个接口，真实实现和测试替身可以互换。
//
// 为什么这么切：本地通知的"什么时候响"是纯逻辑（domain/reminders.dart，本机可测），
// 而"怎么让系统响"是平台通道（只能在真机验）。分开之后，前者能进测试，后者只隔一层。

/// 一条要交给系统的通知
class PlannedNotification {
  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String kind;

  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.kind,
  });

  @override
  String toString() => '#$id $at [$kind] $title';
}

abstract class ReminderNotifier {
  /// 申请通知权限；返回是否拿到
  Future<bool> ensurePermission();

  /// 撤掉本应用的全部待发通知（每次整份重排前先撤）
  Future<void> cancelAll();

  /// 排一条
  Future<void> schedule(PlannedNotification n);

  /// 立刻弹一条（自检用：区分"系统拦了通知"和"排期/接收器没跑"）
  Future<void> showNow(PlannedNotification n);

  /// 当前待发条数（iOS 上限 64；用于自检）
  Future<int> pendingCount();
}
