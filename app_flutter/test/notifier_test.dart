// 通知层测试：排期 → 交给通知系统的调用顺序与内容（用 FakeNotifier，不碰真机）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo.dart';
import 'package:classout/data/settings.dart';
import 'package:classout/domain/reminders.dart';
import 'package:classout/notify/fake_notifier.dart';
import 'package:classout/notify/scheduler.dart';
import 'package:classout/ui/home_shell.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

final DateTime _now = DateTime(2026, 10, 14, 20, 0);

ReminderPlanResult _planFor(BackupBundle b, {ReminderSettings? settings}) => planReminders(
      sem: b.semester!,
      courses: b.courses,
      rules: b.rules,
      times: b.sectionTimes,
      overrides: b.overrides,
      todos: b.todos.where((t) => t.status == 'active').toList(),
      blocks: b.blocks,
      settings: settings ?? ReminderSettings(),
      now: _now,
    );

void main() {
  group('syncNotifications', () {
    test('先撤销再逐条排，id 从 startId 递增', () async {
      final notifier = FakeNotifier();
      final plan = _planFor(_demo());
      final r = await syncNotifications(notifier, plan, startId: 1000);

      expect(notifier.cancelAllCalls, 1, reason: '整份重排前必须先撤销');
      expect(r.scheduled, plan.published.length);
      expect(notifier.scheduled.length, plan.published.length);
      for (var i = 0; i < plan.published.length; i++) {
        final got = notifier.scheduled[i];
        final want = plan.published[i];
        expect(got.id, 1000 + i);
        expect(got.at, want.at);
        expect(got.title, want.title);
        expect(got.body, want.content);
        expect(got.kind, want.kind);
      }
      expect(r.pending, plan.published.length);
    });

    test('没有权限就一条都不排（但已经撤销过旧的）', () async {
      final notifier = FakeNotifier(permissionGranted: false);
      final r = await syncNotifications(notifier, _planFor(_demo()));
      expect(r.granted, isFalse);
      expect(r.scheduled, 0);
      expect(notifier.scheduled, isEmpty);
      expect(notifier.cancelAllCalls, 1);
    });

    test('待发条数不超过预算（iOS/鸿蒙上限 64，我们用 60 留余量）', () async {
      final notifier = FakeNotifier();
      final plan = _planFor(_demo());
      final r = await syncNotifications(notifier, plan);
      expect(r.scheduled, lessThanOrEqualTo(reminderBudget));
      expect(r.pending, lessThanOrEqualTo(reminderBudget));
      expect(reminderBudget, lessThan(64), reason: '要给系统留余量');
    });

    test('关掉简报后不排简报类通知', () async {
      final notifier = FakeNotifier();
      final plan = _planFor(_demo(), settings: ReminderSettings(briefEnabled: false));
      await syncNotifications(notifier, plan);
      expect(notifier.scheduled.any((n) => n.kind == 'brief'), isFalse);
    });
  });

  group('AppSettings 的提醒项', () {
    test('默认值 + 往返', () async {
      final s = AppSettings();
      expect(s.briefEnabled, isTrue);
      expect(s.briefMin, defaultBriefMin);
      expect(s.classLeadMin, defaultClassLeadMin);
      expect(s.reminderSettings.classLeadMin, defaultClassLeadMin);

      final repo = MemoryRepo();
      s.classLeadMin = 30;
      s.briefEnabled = false;
      s.briefMin = 8 * 60;
      await s.save(repo);

      final back = await AppSettings.load(repo);
      expect(back.classLeadMin, 30);
      expect(back.briefEnabled, isFalse);
      expect(back.briefMin, 8 * 60);
    });

    test('坏值/越界回默认（与鸿蒙端一致）', () async {
      final repo = MemoryRepo();
      await repo.setKv('class_lead', '999');
      await repo.setKv('brief_time', '乱写');
      final s = await AppSettings.load(repo);
      expect(s.classLeadMin, defaultClassLeadMin);
      expect(s.briefMin, defaultBriefMin);
    });
  });

  testWidgets('设置页「立即重排提醒」把计划交给通知系统并提示结果', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final notifier = FakeNotifier();
    final repo = MemoryRepo();

    await tester.pumpWidget(MaterialApp(
      home: HomeShell(repo: repo, fallback: _demo(), notifier: notifier),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    final btn = find.text('立即重排提醒');
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(notifier.cancelAllCalls, 1);
    expect(notifier.scheduled, isNotEmpty);
    expect(find.textContaining('已排'), findsOneWidget, reason: '应弹出结果提示');
  });
}
