import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// CI 工作流本身也要能被解析（S-2）：YAML 写错的话 GitHub 直接不跑，
/// 而"没跑"和"跑过了"在界面上长得很像 —— 这正是要靠测试守住的原因。
void main() {
  test('ci.yml 是合法 YAML，且跑的是那两条验收线', () {
    final file = File('.github/workflows/ci.yml');
    expect(file.existsSync(), isTrue, reason: 'CI 工作流被删了？');

    final doc = loadYaml(file.readAsStringSync());
    expect(doc, isA<Map>(), reason: '工作流根节点必须是个映射');
    final root = doc as Map;

    expect(root['name'], 'CI');
    expect(root['on'], isNotNull, reason: '没有触发条件就永远不会跑');
    final jobs = root['jobs'] as Map;
    expect(jobs.keys, containsAll(<String>['verify', 'build']));

    final verify = jobs['verify'] as Map;
    final steps = (verify['steps'] as List).cast<Map>();
    final commands = steps
        .map((s) => s['run'])
        .whereType<String>()
        .join('\n');

    expect(commands, contains('flutter analyze'),
        reason: '验收线第一条：analyze 必须 0 问题');
    expect(commands, contains('flutter test'),
        reason: '验收线第二条：test 必须全绿');
  });
}
