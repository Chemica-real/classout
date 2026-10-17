// 验证「按平台选仓库」这条路：在 VM（≈原生）上解析到 io 实现，
// 并且真的能建库、能读回 —— 只是把 path_provider 的通道 mock 成临时目录。
//
// 这相当于把 main.dart 的启动链路（openRepo → 建库 → HomeShell）跑了一遍，
// 除了"OS 真的给了个目录"之外都是真的。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:classout/data/backup.dart';
import 'package:classout/data/repo_factory.dart';
import 'package:classout/data/sqlite_repo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('classout_factory_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') return tmp.path;
        return null;
      },
    );
    // 让 rootBundle 能读到 assets/schema.sql
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
      final file = File(key);
      if (!file.existsSync()) return null;
      return ByteData.view(file.readAsBytesSync().buffer);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    tmp.deleteSync(recursive: true);
  });

  test('VM 上解析到 SqliteRepo，并在 App 目录里建库', () async {
    final repo = await openRepo();
    addTearDown(repo.close);
    expect(repo, isA<SqliteRepo>());
    expect(File('${tmp.path}/classout.db').existsSync(), isTrue,
        reason: '应该在 path_provider 给的目录里建 classout.db');

    // 空库 → null；导入后能读回
    expect(await repo.load(), isNull);
    final demo = BackupBundle.decode(File('assets/demo_backup.json').readAsStringSync());
    await repo.replaceAll(demo);
    final loaded = await repo.load();
    expect(loaded, isNotNull);
    expect(loaded!.courses.length, demo.courses.length);
    expect(await repo.getKv('motto'), isNull);
    await repo.setKv('motto', '离线课表');
    expect(await repo.getKv('motto'), '离线课表');
  });
}
