// 新手演练的步骤脚本 —— 鸿蒙端 `domain/Guide.ets` 的 Dart 版（纯数据 + 纯函数）。
//
// 模式是「引导条 + 沙箱库」：进入演练时把当前数据整份存进 kv，再换成演练数据；
// 引导条浮在真实界面下方，每一步说明 + 自动切到对应标签页；退出时把 kv 里的数据还原。
//
// 文案保持一致（内容是产品的一部分，改文案不该碰 HomeShell 的逻辑）。

class GuideStep {
  final String title;
  final String body;

  /// 这一步该在哪个标签页：0 课表 / 1 待办 / 2 计划 / 3 设置
  final int tab;

  const GuideStep({required this.title, required this.body, required this.tab});
}

/// 标签页编号（与底部导航一致）
class GuideTab {
  static const int timetable = 0;
  static const int todo = 1;
  static const int plan = 2;
  static const int settings = 3;
}

/// kv：沙箱期间真实数据的备份（JSON）；恢复后删除
const String sandboxBackupKey = 'sandbox_backup';

/// kv：首次启动询问过没有
const String guidePromptedKey = 'guide_prompted';

/// 「首次启动要不要演练」的总开关。
/// 测试里由 `test/flutter_test_config.dart` 关掉 —— 否则每个 pump HomeShell 的用例
/// 都会先弹一个挡住的对话框；要测这条流程的用例自己把它打开。
bool guidePromptEnabled = true;

/// 沙箱学期名（一眼能看出不是自己的课表）
const String demoSemesterName = '演练学期';

List<GuideStep> guideSteps() => const [
      GuideStep(
        title: '这是你的课表',
        body: '演练里已经放好 4 门演示课。点任意一节课的色块，会弹出「换教室 / 调课 / 停课」——'
            '随便改成什么样都行，动的只是演练数据。',
        tab: GuideTab.timetable,
      ),
      GuideStep(
        title: '改一节试试',
        body: '在弹出的面板里把「换教室」那一栏改个地点、点「换到这儿」，课表上的地点当场就变了。'
            '（这就是平时改教室的地方。）',
        tab: GuideTab.timetable,
      ),
      GuideStep(
        title: '待办：打勾完成',
        body: '切到「待办」。演示待办已经在列表里，点最左边的圆圈就把一条标记完成 ——'
            '它会去最下面的「已完成」区，还能恢复或删除。',
        tab: GuideTab.todo,
      ),
      GuideStep(
        title: '新建一条待办',
        body: '点底部「＋ 新建待办」：写标题、选类型（类型那一排最后的「＋ 新建类型」'
            '可以加一个自己的类型）、写备注、挑截止时间，最后保存。',
        tab: GuideTab.todo,
      ),
      GuideStep(
        title: '计划：把待办排进时间',
        body: '切到「计划」。底部「待安排」点开，先点一条待办选中，再点网格上的空白处就排上了；'
            '排好后还能拖动、双指缩放改时长。',
        tab: GuideTab.plan,
      ),
      GuideStep(
        title: '设置',
        body: '最后一站：背景、首页标语、待办类型、不可排时段、计划页时间范围都在这一页。'
            '想看哪个点哪个，改坏了也不要紧。',
        tab: GuideTab.settings,
      ),
      GuideStep(
        title: '演练结束',
        body: '点下面的「完成演练」：演练数据会整份删掉，回到你自己的课表 ——'
            '刚才的每一步都是真实操作，只是做在了沙箱里。',
        tab: GuideTab.settings,
      ),
    ];

int guideStepCount() => guideSteps().length;

bool isLastGuideStep(int index) => index >= guideStepCount() - 1;

int nextGuideStep(int index) {
  final n = index + 1;
  return n > guideStepCount() - 1 ? guideStepCount() - 1 : n;
}

int prevGuideStep(int index) {
  final n = index - 1;
  return n < 0 ? 0 : n;
}

GuideStep guideStepAt(int index) {
  final steps = guideSteps();
  if (index < 0) return steps.first;
  if (index >= steps.length) return steps.last;
  return steps[index];
}
