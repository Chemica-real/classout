// 从 ArkTS `domain/Validate.ets` 移植过来的几条"输入合法性检验"：
// 作息表 / 时段规则 / 生成模板标题 / 考试起止时间。

import 'package:flutter_test/flutter_test.dart';

import 'package:classout/domain/validate.dart';
import 'package:classout/model/types.dart';

SectionTime _st(int section, int start, int end, {bool flexible = false}) =>
    SectionTime(
        semesterId: 1,
        section: section,
        startMin: start,
        endMin: end,
        flexible: flexible);

List<SectionTime> _sections() => [
      _st(1, 480, 530),
      _st(2, 540, 590),
      _st(3, 610, 660),
      _st(4, 670, 720),
    ];

SessionRule _rule(
        {int weekday = 1,
        int start = 1,
        int end = 2,
        String mask = '1111'}) =>
    SessionRule(
        id: 1,
        courseId: 1,
        weekday: weekday,
        startSection: start,
        endSection: end,
        weeksMask: mask);

void main() {
  group('作息表', () {
    test('单节：编号从 1 开始、时间在一天内、结束晚于开始', () {
      expect(validateSectionTime(_st(1, 480, 530)).ok, isTrue);
      expect(validateSectionTime(_st(0, 480, 530)).message, '节次编号要从 1 开始');
      expect(validateSectionTime(_st(1, 480, 480)).message, '第 1 节的结束时间必须晚于开始时间');
      expect(validateSectionTime(_st(1, 500, 1450)).message, '第 1 节的时间要在 00:00–24:00 之间');
    });

    test('整表：不能为空、编号不能重复', () {
      expect(validateSectionTimes([]).message, '至少要有 1 个节次');
      expect(validateSectionTimes(_sections()).ok, isTrue);
      final dup = [..._sections(), _st(3, 700, 750)];
      expect(validateSectionTimes(dup).message, '节次编号 3 重复了');
    });
  });

  group('时段规则', () {
    test('星期 / 起止节次 / 周次掩码 / 作息表存在性', () {
      final sections = _sections();
      expect(validateSessionRule(_rule(), sections).ok, isTrue);
      expect(validateSessionRule(_rule(weekday: 0), sections).message, '星期要选周一到周日');
      expect(validateSessionRule(_rule(start: 3, end: 2), sections).message, '开始节次不能晚于结束节次');
      expect(validateSessionRule(_rule(start: 9, end: 9), sections).message, '作息表里没有第 9 节');
      expect(validateSessionRule(_rule(mask: ''), sections).message, '周次是空的，请先设置学期总周数');
      expect(validateSessionRule(_rule(mask: '0000'), sections).message, '至少要勾选一个上课周次');
    });

    test('spanOfRule：首节次开始 → 末节次结束', () {
      expect(spanOfRule(_rule(start: 2, end: 3), _sections()), [540, 660]);
      expect(spanOfRule(_rule(start: 9, end: 9), _sections()), isEmpty);
    });

    test('findRuleConflicts：同一天 + 周次相交 + 时间重叠才算', () {
      final sections = _sections();
      final a = _rule(start: 1, end: 2);
      final b = SessionRule(
          id: 2, courseId: 2, weekday: 1, startSection: 2, endSection: 3,
          weeksMask: '0110');
      final c = SessionRule(
          id: 3, courseId: 3, weekday: 2, startSection: 1, endSection: 2,
          weeksMask: '1111');
      final d = SessionRule(
          id: 4, courseId: 4, weekday: 1, startSection: 3, endSection: 4,
          weeksMask: '1000');
      final all = findRuleConflicts([a, b, c, d], sections);
      expect(all.length, 1, reason: '只有 a 和 b 撞了');
      expect(all.first.a, 1);
      expect(all.first.b, 2);
      expect(all.first.overlapStart, 540);
      expect(all.first.overlapEnd, 590);
    });
  });

  group('模板标题 / 截止参数', () {
    test('空 / 超长 / 未知变量', () {
      expect(validateTemplateTitle('   ').message, '模板不能为空');
      expect(validateTemplateTitle('あ' * 61).message, contains('模板太长了'));
      final bad = validateTemplateTitle('%D作业 %M');
      expect(bad.ok, isFalse);
      expect(bad.unknown, ['%M']);
      expect(bad.message, contains('不是支持的变量'));
      expect(bad.message, contains('%C %c %D %d %W %T %N %R'));
    });

    test('支持的变量与普通文字都算合法', () {
      expect(validateTemplateTitle('%D作业').ok, isTrue);
      expect(validateTemplateTitle('%c 第 %N 次作业（%T 提交）').ok, isTrue);
    });

    test('截止参数：days 1–365、weekday 1–7', () {
      expect(validateTemplateDdl('days', '3').ok, isTrue);
      expect(validateTemplateDdl('days', '0').message, '「N 天后」的 N 要在 1–365 之间');
      expect(validateTemplateDdl('days', '366').ok, isFalse);
      expect(validateTemplateDdl('weekday', '7').ok, isTrue);
      expect(validateTemplateDdl('weekday', '8').message, '「指定星期几」要选周一到周日');
      expect(validateTemplateDdl('none', '').ok, isTrue);
    });
  });

  group('考试起止', () {
    test('缺一不可 / 必须同一天 / 结束晚于开始', () {
      expect(validateExamRange('2026-10-20 09:00', '2026-10-20 11:00').ok, isTrue);
      expect(validateExamRange('2026-10-20 09:00', '').message, '考试的开始和结束时间都要选');
      expect(validateExamRange('2026-10-20 09:00', '2026-10-21 11:00').message,
          '考试的开始和结束要在同一天');
      expect(validateExamRange('2026-10-20 11:00', '2026-10-20 09:00').message,
          '考试的结束时间必须晚于开始时间');
    });

    test('examRangeOf 取开始那天与起止分钟', () {
      final r = examRangeOf('2026-10-20 09:00', '2026-10-20 11:30');
      expect(r.date, '2026-10-20');
      expect(r.startMin, 9 * 60);
      expect(r.endMin, 11 * 60 + 30);
    });
  });
}
