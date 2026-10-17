import 'repo.dart';

/// web：没有文件系统与 FFI，用内存仓库（演示版行为：刷新回到演示数据）
Future<ClassOutRepo> openRepo() async => MemoryRepo();
