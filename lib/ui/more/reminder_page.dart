import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/reminder.dart';
import '../../core/rules/reminder_schedule.dart';
import '../common/dialogs.dart';
import '../common/section_header.dart';

/// 「更多 → 提醒」页（ADR-097）。
///
/// 三块：**总开关**、**权限与系统限制**、**两档提前量**。
///
/// 这一页有一半内容不是"设置"，而是**如实交代系统限制** —— 因为真机实测
/// （小米 15 Pro / HyperOS，2026-10-03）发现：本应用的提醒能不能按时到，
/// 有一半取决于系统侧的两个开关，而其中「自启动」**没有公开 API 可查**，
/// App 读不到它。读不到就不能假装知道，只能把步骤写清楚让人自己去开。
class ReminderPage extends StatefulWidget {
  const ReminderPage({super.key, required this.app});

  final AppController app;

  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

/// 界面上能挑的提前量（**有意做成一份固定清单**，不开任意输入）。
///
/// 为什么不像"任意数值"那样放开：提前量的用途是"在到期之前提醒我一次"，
/// 5 分钟与 7 分钟对使用者没有区别，而任意输入会带来"填了 0 / 填了 100000"
/// 这类要先解释再拒绝的交互。这与"标识色刻意不放开成任意取色"是同一条取舍。
///
/// 模型层（[ReminderLead]）仍然接受任意合法分钟数 —— 开放的余地留给以后，
/// 收敛的交互留给现在。
const List<int> reminderLeadPresets = <int>[
  5, 10, 15, 30, 45, 60, 120, 180, 720, 1440, 2880, 10080,
];

class _ReminderPageState extends State<ReminderPage> {
  AppController get _app => widget.app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        final prefs = _app.prefs;
        final supported = _app.remindersSupported;

        return Scaffold(
          appBar: AppBar(title: const Text('提醒')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              if (!supported)
                const ListTile(
                  leading: Icon(Icons.desktop_windows_outlined),
                  title: Text('电脑端不做提醒'),
                  subtitle: Text('手机端才有。两端各存各的数据，这一项不跟着导出走。'),
                ),

              if (supported) ...<Widget>[
                const SectionHeader('总开关'),
                SwitchListTile(
                  title: const Text('到点提醒我'),
                  subtitle: Text(
                    '只提醒设了具体时间的任务（例如 10-03 18:00）。'
                    '只写到哪天、没写钟点的不提醒。',
                    style: theme.textTheme.labelSmall,
                  ),
                  value: prefs.reminderEnabled,
                  onChanged: _toggleEnabled,
                ),

                const SectionHeader('两档提前量'),
                for (var slot = 0; slot < prefs.reminderLeads.length; slot++)
                  _LeadTile(
                    slot: slot,
                    lead: prefs.reminderLeads[slot],
                    enabled: prefs.reminderEnabled,
                    onToggle: (value) => _app.setReminderLeadEnabled(slot, value),
                    onPickMinutes: (minutes) =>
                        _app.setReminderLeadMinutes(slot, minutes),
                  ),

                const SectionHeader('系统那边还要两件事'),
                _PermissionTile(app: _app),
                const _AutostartTile(),
              ],

              if (_app.reminderError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    '上一次排期没成功：${_app.reminderError}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleEnabled(bool value) async {
    await _app.setReminderEnabled(value);
    if (!mounted || !value) return;
    // 打开之后就地问一次权限的真实状态：用户在系统里点过"不允许"的话，
    // 开关是开的、通知却永远不来 —— 这种"看着像好了"最误导人。
    final allowed = await _app.notificationsAllowed();
    if (!mounted) return;
    showToast(
      context,
      allowed ? '已打开提醒' : '提醒已打开，但系统还没允许通知 —— 见上面那一条',
      error: !allowed,
    );
  }
}

/// 一档提前量：开关 + 提前多久。
class _LeadTile extends StatelessWidget {
  const _LeadTile({
    required this.slot,
    required this.lead,
    required this.enabled,
    required this.onToggle,
    required this.onPickMinutes,
  });

  final int slot;
  final ReminderLead lead;

  /// 总开关关着时，两档置灰但**仍然显示当前值** —— 灰掉不等于清掉。
  final bool enabled;

  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onPickMinutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 清单里没有这个值时给 `null`（`DropdownButton` 不允许 value 不在 items 里）——
    // 于是界面上显示占位文案，而不是崩掉。
    final value = reminderLeadPresets.contains(lead.minutes) ? lead.minutes : null;
    return ListTile(
      enabled: enabled,
      title: Text('第 ${slot + 1} 档'),
      subtitle: Text(
        lead.enabled ? '提前 ${describeLeadMinutes(lead.minutes)}' : '这一档已关掉',
        style: theme.textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DropdownButton<int>(
            value: value,
            hint: Text(describeLeadMinutes(lead.minutes)),
            underline: const SizedBox.shrink(),
            items: <DropdownMenuItem<int>>[
              for (final minutes in reminderLeadPresets)
                DropdownMenuItem<int>(
                  value: minutes,
                  child: Text(describeLeadMinutes(minutes)),
                ),
            ],
            onChanged: enabled
                ? (picked) {
                    if (picked != null) onPickMinutes(picked);
                  }
                : null,
          ),
          Switch(
            value: lead.enabled,
            onChanged: enabled ? onToggle : null,
          ),
        ],
      ),
    );
  }
}

/// 系统通知权限的真实状态 + 一个"去申请"的入口。
class _PermissionTile extends StatelessWidget {
  const _PermissionTile({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<bool>(
      future: app.notificationsAllowed(),
      builder: (context, snapshot) {
        final allowed = snapshot.data;
        final text = switch (allowed) {
          null => '正在查…',
          true => '已允许',
          false => '还没允许 —— 系统不会弹出任何通知',
        };
        return ListTile(
          leading: Icon(
            allowed == true
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
          ),
          title: const Text('通知权限'),
          subtitle: Text(text, style: theme.textTheme.labelSmall),
          trailing: allowed == false
              ? TextButton(
                  onPressed: () async {
                    await app.setReminderEnabled(true);
                    if (!context.mounted) return;
                    final now = await app.notificationsAllowed();
                    if (!context.mounted) return;
                    showToast(context, now ? '已允许' : '系统里没有允许', error: !now);
                  },
                  child: const Text('再申请一次'),
                )
              : null,
        );
      },
    );
  }
}

/// 「自启动」这件事**只能这么办** —— 这一段是本页最需要如实交代的地方。
class _AutostartTile extends StatelessWidget {
  const _AutostartTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: const Icon(Icons.restart_alt_outlined),
      title: const Text('自启动（小米 / HyperOS 必开）'),
      subtitle: Text(
        '不开的话：手机重启后提醒会静默消失，不报错也不提示。'
        '这个开关系统没给查询接口，App 读不到，只能你自己去看一眼。',
        style: theme.textTheme.labelSmall,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('打开「自启动」'),
          content: const SingleChildScrollView(
            child: Text(
              '系统设置 → 应用设置 → 应用管理 → GuideLine → 自启动 → 打开\n\n'
              '为什么必须开：小米在系统层拦掉了"应用没在运行时，被闹钟唤醒"这件事。'
              '实测记录（2026-10-03，小米 15 Pro / HyperOS / Android 16）：\n'
              '· 没开自启动时，闹钟到点照样响，但系统拒绝把 App 拉起来，'
              '通知被直接丢弃 —— 日志里只有一句 "process is not permitted to auto start"；\n'
              '· 开了之后，重启也能把还没投递的补上。\n\n'
              '这一条没有替代做法，也不是本应用能绕过的限制。',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
  }
}
