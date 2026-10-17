// 本次启动的关键结果 —— 鸿蒙端 `Index.ets → writeRunReport()`：
// 供「备份与恢复 → 诊断信息」显示。
//
// 为什么值得记：真机出问题时这是最省事的一条信息通道 —— 用户不用连电脑、不用抓日志，
// 打开设置页截图就能看到初始化每一步到底成没成（初始化成没成、补生成几条、
// 提醒写了几条、有没有超预算）。

import 'repo.dart';

const String runReportKv = 'last_run_report';

/// 内存态（本进程最近一次写的报告；备份页直接读它，免得再查一次库）
String lastRunReport = '';

Future<void> writeRunReport(ClassOutRepo repo, String text) async {
  lastRunReport = text;
  try {
    await repo.setKv(runReportKv, text);
  } catch (_) {
    // 写失败不影响启动
  }
}

Future<void> loadRunReport(ClassOutRepo repo) async {
  try {
    lastRunReport = await repo.getKv(runReportKv) ?? '';
  } catch (_) {
    lastRunReport = '';
  }
}
