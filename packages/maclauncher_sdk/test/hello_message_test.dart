// hello 线形测试：直接 import src 内部的纯函数 buildHelloMessage，
// 不开 socket、不构造 MacLauncherSdk 实例。
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:maclauncher_sdk/src/client.dart' show buildHelloMessage;
import 'package:test/test.dart';

void main() {
  final capabilities = CapabilitySet(
    services: [
      ServiceDeclaration(
        id: 'inference',
        name: '推理服务',
        methods: const ['start', 'recycle', 'status', 'logs'],
      ),
    ],
    app: const ['openWindow'],
  );

  test('必填字段保持既有线形', () {
    final hello = buildHelloMessage(
      projectId: 'com.example.app',
      appSessionId: 's-1',
      capabilities: capabilities,
    );
    expect(hello['type'], 'hello');
    expect(hello['protocolVersion'], kProtocolVersion);
    expect(hello['projectId'], 'com.example.app');
    expect(hello['appSessionId'], 's-1');
    expect(hello['capabilities'], isA<Map<String, Object?>>());
  });

  test('未提供 projectName/entry 时字段省略（老启动器看到旧形状）', () {
    final hello = buildHelloMessage(
      projectId: 'com.example.app',
      appSessionId: 's-1',
      capabilities: capabilities,
    );
    expect(hello.containsKey('projectName'), isFalse);
    expect(hello.containsKey('entry'), isFalse);
  });

  test('提供 projectName/entry 时随 hello 上报', () {
    final hello = buildHelloMessage(
      projectId: 'com.example.app',
      appSessionId: 's-1',
      capabilities: capabilities,
      projectName: '示例应用',
      entry: SdkEntry.appBundle('/Applications/Foo.app'),
    );
    expect(hello['projectName'], '示例应用');
    final entry = hello['entry']! as Map<String, Object?>;
    expect(entry['kind'], 'app');
    expect(entry['path'], '/Applications/Foo.app');
  });

  test('pending-approval 拒绝原因常量固定', () {
    expect(kRejectReasonPendingApproval, 'pending-approval');
  });
}
