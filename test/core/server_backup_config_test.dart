import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/server_backup_config.dart';

/// 服务器同步的配置校验：**只接受 https、必须带 64 位证书指纹**。
void main() {
  const pin =
      '3f786850e387550fdab836ed7e6dc881de23001b8ee5a7d4a32a7f0f7a8f3c7f';

  test('地址去尾斜杠、指纹去分隔符并转小写', () {
    final cleaned = const ServerBackupConfig(
      baseUrl: '  https://120.55.11.161:8443/  ',
      fingerprint: '3F:78:68:50:E3:87:55:0F:DA:B8:36:ED:7E:6D:C8:81'
          'DE:23:00:1B:8E:E5:A7:D4:A3:2A:7F:0F:7A:8F:3C:7F',
    ).normalized();
    expect(cleaned.baseUrl, 'https://120.55.11.161:8443');
    expect(cleaned.fingerprint.length, 64);
    expect(cleaned.fingerprint, cleaned.fingerprint.toLowerCase());
  });

  test('缺地址 / 非 https / 带路径 / 缺指纹 / 指纹长度不对，都给出可读原因', () {
    expect(
      const ServerBackupConfig().validate(),
      contains('服务器地址'),
    );
    expect(
      const ServerBackupConfig(baseUrl: 'http://example.com', fingerprint: pin)
          .validate(),
      contains('https://'),
    );
    expect(
      const ServerBackupConfig(
        baseUrl: 'https://example.com/api',
        fingerprint: pin,
      ).validate(),
      contains('不要带路径'),
    );
    expect(
      const ServerBackupConfig(baseUrl: 'https://example.com').validate(),
      contains('指纹'),
    );
    expect(
      const ServerBackupConfig(
        baseUrl: 'https://example.com',
        fingerprint: 'abcd',
      ).validate(),
      contains('64 位'),
    );
  });

  test('配置齐全时 isConfigured 为真，host / port / displayHost 正确', () {
    const config = ServerBackupConfig(
      enabled: true,
      baseUrl: 'https://120.55.11.161:8443',
      fingerprint: pin,
    );
    expect(config.validate(), isNull);
    expect(config.isConfigured, isTrue);
    expect(config.host, '120.55.11.161');
    expect(config.port, 8443);
    expect(config.displayHost, '120.55.11.161:8443');
  });
}
