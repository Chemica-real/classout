import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'repo.dart';
import 'sqlite_repo.dart';

/// 原生：App 数据目录下的 classout.db，建库用打包进来的 assets/schema.sql
Future<ClassOutRepo> openRepo() async {
  final dir = await getApplicationSupportDirectory();
  final schema = await rootBundle.loadString('assets/schema.sql');
  return SqliteRepo.withSchema(
    path: '${dir.path}/classout.db',
    schemaSql: schema,
  );
}
