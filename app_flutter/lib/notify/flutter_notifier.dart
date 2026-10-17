// 真实实现：flutter_local_notifications（iOS 走 UNUserNotificationCenter，
// Android 走 AlarmManager + 通知渠道）。
//
// ⚠️ 这台 Linux 机器只能保证**编译与调用顺序正确**；权限弹窗、锁屏展示、
//    免打扰行为必须在真机上验（HANDOFF §42 记了这条）。

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
      return ok ?? false;
    }
    return true; // 其它平台（含桌面/web）交给系统兜底
  }

  @override
  Future<void> cancelAll() async {
    await _init();
    await _plugin.cancelAll();
  }

  @override
  Future<void> schedule(PlannedNotification n) async {
    await _init();
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
    await _plugin.zonedSchedule(
      id: n.id,
      scheduledDate: tz.TZDateTime.from(n.at, tz.local),
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      title: n.title,
      body: n.body,
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
