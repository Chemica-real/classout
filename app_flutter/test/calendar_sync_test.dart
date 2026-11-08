import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/calendar_sync.dart';

BackupBundle _demo() =>
    BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());

void main() {
  test('可选日历：生成的课程事件带 ClassOUT 标记', () {
    final b = _demo();
    final now = DateTime(2026, 11, 9, 8);
    final events = buildCalendarEvents(b, now);
    expect(events, isNotEmpty);
    expect(events.every((e) => e.description.startsWith('ClassOUT')), isTrue);
    expect(events.any((e) => e.title.isNotEmpty), isTrue);
    expect(events.every((e) => e.endMs > e.startMs), isTrue);
  });
}
