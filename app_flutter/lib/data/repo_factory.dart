// 按平台选仓库实现：
//   原生（iOS/Android/macOS/Linux）→ SqliteRepo（真文件库）
//   web                          → MemoryRepo（浏览器里没有 sqlite3 ↔ FFI）
//
// 条件导出：`dart.library.io` 在原生/VM 上为 true，在 web 上为 false。
export 'repo_factory_web.dart' if (dart.library.io) 'repo_factory_io.dart';
