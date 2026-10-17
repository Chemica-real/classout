// 真实实现：flutter_local_notifications（iOS 走 UNUserNotificationCenter，
// Android 走 AlarmManager + 通知渠道）。
//
// ⚠️ 这台 Linux 机器只能保证**编译与调用顺序正确**；权限弹窗、锁屏展示、
//    免打扰行为必须在真机上验（HANDOFF §42 记了这条）。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notifier.dart';

class FlutterNotifier implements ReminderNotifier {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  static const String _channelId = 'classout_reminders';
  static const String _channelName = '上课与截止提醒';

  Future<void> _init() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // 权限首次进入时显式请求（见 ensurePermission），不在初始化时弹
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    // 显式建渠道：ColorOS 上曾出现"排上了但通知栏没有、渠道也没建"的情况，
    // 手动建一次可以让渠道先出现在系统设置里，便于排查是不是被系统拦了。
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      try {
        await android.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'ClassOUT 生成的上课与截止提醒',
          importance: Importance.high,
        ));
      } catch (e) {
        debugPrint('[ClassOUT] create channel failed: $e');
      }
    }
    debugPrint('[ClassOUT] notifier init done');
    _inited = true;
  }

  @override
  Future<bool> ensurePermission() async {
    await _init();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final ok =
          await ios.requestPermissions(alert: true, badge: true, sound: true);
      return ok ?? false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final ok = await android.requestNotificationsPermission();
      // Android 12+ 的「闹钟和提醒」是**另一个**特殊权限：没有它，
      // exactAllowWhileIdle 会抛 exact_alarms_not_permitted（真机实测）。
      // 这里顺带请求一次；用户拒绝也不阻断 —— schedule 会退回不精确模式。
      try {
        await android.requestExactAlarmsPermission();
      } catch (_) {
        // 老系统没有这个权限，忽略
      }
      return ok ?? false;
    }
    return true; // 其它平台（含桌面/web）交给系统兜底
  }

  @override
  Future<void> cancelAll() async {
    await _init();
    debugPrint('[ClassOUT] cancelAll');
    await _plugin.cancelAll();
  }

  @override
  Future<void> schedule(PlannedNotification n) async {
    await _init();
    debugPrint('[ClassOUT] schedule #${n.id} at ${n.at} kind=${n.kind}');
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'ClassOUT 生成的上课与截止提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    final when = tz.TZDateTime.from(n.at, tz.local);
    // ⚠️ 真机（ColorOS / Android 14）实测：`exactAllowWhileIdle` 排下去的闹钟
    // 到点确实唤醒了接收器，但通知栏没有任何 NotificationRecord；同一条用
    // `show()` 立刻弹就能显示。换成不精确模式后复测通过。
    // 提醒晚几分钟无所谓，**能弹出来**更重要，所以这里固定用 inexact。
    await _plugin.zonedSchedule(
      id: n.id,
      scheduledDate: when,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      title: n.title,
      body: n.body,
      payload: n.kind,
    );
  }

  @override
  Future<void> showNow(PlannedNotification n) async {
    await _init();
    debugPrint('[ClassOUT] showNow #${n.id}');
    await _plugin.show(
      id: n.id,
      title: n.title,
      body: n.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'ClassOUT 生成的上课与截止提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: n.kind,
    );
  }

  @override
  Future<int> pendingCount() async {
    await _init();
    final pending = await _plugin.pendingNotificationRequests();
    return pending.length;
  }
}
