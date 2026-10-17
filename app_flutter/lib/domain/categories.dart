// 待办类型（category）—— 从 domain/Categories.ets 移植。
//
// 三个约定（和鸿蒙端一样，都是用户拍定的）：
// 1. 内置固定四个：作业 / 自学 / 考试 / 无，**不能删**；
// 2. 「其他」(other) 已退役，只为兼容存量数据；新建待办**不再写它**；
// 3. 自定义类型直接用名字当 key；删类型时调用方负责把在用的待办改成 'none'。
//
// 存储形态：kv 里一行一个名字（'\n' 分隔）。

const String legacyOther = 'other';

/// 自定义类型名最长几个字
const int categoryNameMax = 8;

/// 自定义类型最多几个
const int categoryMaxCount = 20;

const String _sep = '\n';

class CategoryOption {
  final String key;
  final String label;
  final bool builtin;
  const CategoryOption(this.key, this.label, this.builtin);

  Map<String, dynamic> toJson() =>
      {'key': key, 'label': label, 'builtin': builtin};
}

class CategoryVerdict {
  final bool ok;
  final String message;
  const CategoryVerdict(this.ok, this.message);

  Map<String, dynamic> toJson() => {'ok': ok, 'message': message};
}

const List<String> _reservedKeys = [
  'homework',
  'self',
  'exam',
  'none',
  legacyOther
];
const List<String> _reservedLabels = ['作业', '自学', '考试', '无', '其他'];

List<CategoryOption> builtinCategoryOptions() => const [
      CategoryOption('homework', '作业', true),
      CategoryOption('self', '自学', true),
      CategoryOption('exam', '考试', true),
      CategoryOption('none', '无', true),
    ];

String builtinLabel(String key) {
  for (final o in builtinCategoryOptions()) {
    if (o.key == key) return o.label;
  }
  return '';
}

bool _isReservedName(String name) =>
    _reservedKeys.contains(name) || _reservedLabels.contains(name);

/// 解析 kv 里的自定义类型：坏数据（空行/重复/保留字/超长）静默丢掉
List<String> parseCustomCategories(String raw) {
  final out = <String>[];
  for (final p in raw.split(_sep)) {
    final name = p.trim();
    if (name.isEmpty ||
        name.length > categoryNameMax ||
        _isReservedName(name)) {
      continue;
    }
    if (!out.contains(name)) out.add(name);
  }
  return out;
}

String serializeCustomCategories(List<String> list) =>
    parseCustomCategories(list.join(_sep)).join(_sep);

CategoryVerdict validateCategoryName(String name, List<String> custom) {
  final t = name.trim();
  if (t.isEmpty) return const CategoryVerdict(false, '类型名不能为空');
  if (t.length > categoryNameMax) {
    return const CategoryVerdict(false, '类型名最多 $categoryNameMax 个字');
  }
  if (_isReservedName(t) || custom.contains(t)) {
    return const CategoryVerdict(false, '这个类型已经有了');
  }
  if (custom.length >= categoryMaxCount) {
    return const CategoryVerdict(false, '自定义类型最多 $categoryMaxCount 个');
  }
  return const CategoryVerdict(true, '');
}

List<String> addCustomCategory(List<String> custom, String name) {
  final t = name.trim();
  final out = List<String>.from(custom);
  if (t.isNotEmpty && !out.contains(t) && !_isReservedName(t)) out.add(t);
  return out;
}

List<String> removeCustomCategory(List<String> custom, String name) =>
    custom.where((c) => c != name).toList();

List<CategoryOption> allCategoryOptions(List<String> custom) {
  final out = List<CategoryOption>.from(builtinCategoryOptions());
  for (final name in custom) {
    out.add(CategoryOption(name, name, false));
  }
  return out;
}

/// 类型的显示名：'none' → ''（卡片上不画标签）、内置 → 中文、自定义 → 名字本身、
/// 认不出的（含退役的 'other'）→ 尽量给人话，绝不显示空白
String categoryLabel(String key, List<String> custom) {
  if (key == 'none' || key.isEmpty) return '';
  if (key == legacyOther) return '其他';
  final b = builtinLabel(key);
  if (b.isNotEmpty) return b;
  return key;
}
