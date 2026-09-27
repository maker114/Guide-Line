import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/ai_config.dart';
import '../common/dialogs.dart';
import '../theme/shape_tokens.dart';

/// AI 设置（《定义与边界》§10）。
///
/// 这是全应用**唯一会联网**的功能，所以这一页要把边界讲清楚：
///   · 请求只发到你自己填的地址，没有硬编码的第三方服务器；
///   · **只发项目名称、「有什么问题 / 思路」、清单条目** —— 灵感原文、事件任务、
///     其它项目都不发；
///   · `apiKey` 存在系统安全存储里，**不进偏好文件、不进备份、不进导出**；
///   · 提示词与模型返回的原文都不落盘，只有你确认过的结果写进「如何解决」；
///   · 开关**即时生效**，地址 / 模型 / Key 只在你按「保存」时写入 ——
///     「测试连接」用临时配置试跑，**一个字都不存**。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.app});

  final AppController app;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  bool _loading = true;
  bool _keyStored = false;
  bool _testing = false;
  bool _testOk = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await widget.app.readAiConfig();
    if (!mounted) return;
    setState(() {
      _baseUrl.text = config.baseUrl;
      _model.text = config.model;
      // 安全存储里已经有 Key 时**不把它显示出来**：只给一个"已保存"的标记，
      // 想换就重新输入（读出来回显没有好处，只有被旁人看到的风险）
      _keyStored = config.apiKey.isNotEmpty;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 整理'),
        actions: <Widget>[
          TextButton(
            // 测试连接期间**不许保存**（Q-8）：`_save` 会先改偏好再 await 写安全存储，
            // 而 `_testConnection` 是"读偏好 + 读 Key"，两条路交错就会测到
            // "新地址 + 旧 Key"这种并不存在的组合，结果与实际保存后的行为对不上。
            onPressed: (_loading || _testing) ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: <Widget>[
                // 总开关：**只决定"显不显示"**，不动已经填好的地址 / 模型 / Key。
                // 关掉之后，清单里那条「AI 整理成计划」入口就不再出现；
                // 这一页本身要留着 —— 不然关掉之后就再也打不开了。
                SwitchListTile(
                  value: widget.app.aiEnabled,
                  title: const Text('启用 AI 整理'),
                  subtitle: Text(
                    widget.app.aiEnabled ? '关掉后项目里不再出现 AI 整理入口，配置保留' : '已关闭',
                    style: theme.textTheme.bodySmall,
                  ),
                  onChanged: (value) => setState(() => widget.app.setAiEnabled(value)),
                ),
                const Divider(height: 1),
                // 「什么时候生效」这一句必须写在改的地方旁边：
                // 开关是**即时生效**的，而地址 / 模型 / Key 要按「保存」——
                // 两者混在一起时，用户会以为填完就已经存住了。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '开关即时生效；下面的地址 / 模型 / Key 要按右上角「保存」才写入。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _Field(
                  label: 'API 地址',
                  hint: AiConfig.defaultBaseUrl,
                  controller: _baseUrl,
                  helper: '填根地址即可，会自动补 /chat/completions',
                ),
                _Field(
                  label: '模型',
                  hint: AiConfig.defaultModel,
                  controller: _model,
                  helper: '默认 deepseek-flash；换别的兼容端点时填那边的模型名',
                ),
                _Field(
                  label: 'API Key',
                  hint: _keyStored ? '已保存，重新输入可替换' : '粘贴你的 Key',
                  controller: _apiKey,
                  obscure: true,
                  helper: '存在系统安全存储里，不进备份、不进导出',
                ),
                if (_keyStored)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _clearKey,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清除已保存的 Key'),
                      ),
                    ),
                  ),
                // 「测试连接」：把**实际请求的地址**和**服务端原话**都摆出来。
                // 加它的原因是一次真实的排查困难 —— 用户在手机上看到"没有这个网站"，
                // 但地址栏里到底存的是什么、拼成了什么请求，界面上完全看不到，
                // 只能靠猜。这里一次点击就能定位（地址错 / 密钥错 / 被限流）。
                //
                // 它**不写任何配置**：测试失败之后用户往往直接返回，
                // "先存再测"等于把那个错地址 / 错 Key 悄悄留在了库里。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.bolt_outlined, size: 18),
                        label: Text(_testing ? '测试中…' : '测试连接'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '只发一句测试文字，不含你的数据；不会保存',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (_testOk ? theme.colorScheme.primary : theme.colorScheme.error)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                      ),
                      child: SelectableText(
                        _testResult!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                const Divider(height: 32),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('会发出去什么', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      // 字段名三处一致（Q4）：项目详情页、这一页的说明、线上提示词
                      // （`ai_client.dart`）都写「有什么问题 / 思路」与「实现清单」。
                      _Bullet('项目名称、项目「有什么问题 / 思路」、清单条目文本与勾选状态，'
                          '以及一段要求它只整理不新增的固定提示词'),
                      const SizedBox(height: 12),
                      Text('不会发出去什么', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      _Bullet('灵感原文、事件与任务、其它项目、设备信息；'
                          '提示词与模型返回的原文也都不落盘'),
                      const SizedBox(height: 12),
                      Text('请求只会发到你上面填的地址。', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _save() async {
    final config = AiConfig(
      baseUrl: _baseUrl.text,
      apiKey: _apiKey.text,
      model: _model.text,
    );
    final error = await widget.app.saveAiConfig(config);
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    final saved = await widget.app.readAiConfig();
    if (!mounted) return;
    setState(() {
      _apiKey.clear();
      _keyStored = saved.apiKey.isNotEmpty;
    });
    showToast(context, '已保存');
  }

  Future<void> _clearKey() async {
    // 只动**已保存的那把 Key**：这里若拿输入框里的地址 / 模型去写，
    // 就等于"点一下清除，顺手把还没按保存的编辑也存了"，跟这一页新写下的
    // "地址 / 模型 / Key 要按「保存」才写入"自相矛盾。
    final stored = await widget.app.readAiConfig();
    if (!mounted) return;
    final error = await widget.app.saveAiConfig(
      AiConfig(baseUrl: stored.baseUrl, apiKey: '', model: stored.model),
    );
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    setState(() => _keyStored = false);
    showToast(context, '已清除');
  }

  /// 真的发一次请求，把**实际地址**与**服务端原话**显示出来。
  ///
  /// 只发一句固定的测试文字，**不带用户任何数据** —— 这一点也写在按钮旁边。
  ///
  /// **用临时配置测，一个字都不落盘**：以前是"先 `saveAiConfig` 再测"，可用户
  /// 测失败（地址写错、Key 粘错）之后多半直接返回，那份错配置就已经存住了，
  /// 下一次真用 AI 整理时才炸 —— 那时他已经不记得自己试过什么。
  /// 现在测试与保存彻底分开：测出来的问题当场看得见，存不存由他按「保存」决定。
  Future<void> _testConnection() async {
    // 已保存的 Key **不在输入框里回显**（见 _load），所以框里为空时沿用安全存储里
    // 那一把 —— 否则"只改地址、不改 Key"的人一测就得到"还没填 API Key"。
    final stored = await widget.app.readAiConfig();
    if (!mounted) return;
    final typedKey = _apiKey.text.trim();
    final draft = AiConfig(
      baseUrl: _baseUrl.text,
      apiKey: typedKey.isEmpty ? stored.apiKey : typedKey,
      model: _model.text,
    );

    setState(() {
      _testing = true;
      _testResult = null;
    });

    final result = await widget.app.testAiConnection(draft);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      // 成功时补一句"还没保存"：不然用户会以为测通 = 存好了，
      // 关掉页面再回来发现地址还是旧的（这正是要避免的那类惊讶）。
      _testResult = result.ok ? '${result.message}\n\n还没保存：按右上角「保存」才会写入' : result.message;
    });
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
    this.helper,
    this.obscure = false,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final String? helper;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              helperText: helper,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('· ', style: theme.textTheme.bodySmall),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
