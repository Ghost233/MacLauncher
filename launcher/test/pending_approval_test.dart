import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/settings_page.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'launcher_test_harness.dart';

/// 待批准 UI 测试（#45/#49）：pending 注册表与批准编排都是真实的，只有
/// 没有 socket 服务器——管理页直接驱动两者。批准对话框的 entry 校验走真实
/// 文件系统（app 形态需要 Contents/Info.plist），测试在 temp 里建真包。
void main() {
  testWidgets('批准流：待批准卡片 → 对话框 → 批准落库 → runtime 卡片', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create();
      try {
        harness.enableDiscovery();
        // A real on-disk bundle: app entries require Contents/Info.plist.
        Directory('${harness.directory.path}/Foo.app/Contents')
            .createSync(recursive: true);
        File('${harness.directory.path}/Foo.app/Contents/Info.plist')
            .writeAsStringSync('');
        harness.pending.record(
          projectId: 'com.ghost.newapp',
          projectName: '新应用',
          services: [
            ServiceDeclaration(id: 'svc', name: '服务', methods: ['status']),
          ],
          entry: SdkEntry.appBundle('${harness.directory.path}/Foo.app'),
          sourceProcessPath: '/Applications/Foo.app/Contents/MacOS/foo',
        );

        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();

        // 待批准区与事实字段。
        expect(find.text('待批准'), findsOneWidget);
        expect(find.text('新应用'), findsOneWidget);
        expect(find.text('项目标识：com.ghost.newapp'), findsOneWidget);
        expect(find.text('服务：服务（svc）'), findsOneWidget);
        expect(
          find.text('来源进程：/Applications/Foo.app/Contents/MacOS/foo'),
          findsOneWidget,
        );
        expect(find.textContaining('首次发现：'), findsOneWidget);

        // 批准对话框：核对身份与来源。
        await tester.tap(find.text('批准…'));
        await tester.pumpAndSettle();
        expect(find.text('批准关联'), findsOneWidget);
        expect(
          find.textContaining('批准「新应用」（com.ghost.newapp）与启动器关联？'),
          findsOneWidget,
        );
        expect(
          find.textContaining('入口：${harness.directory.path}/Foo.app'),
          findsOneWidget,
        );

        await tester.tap(find.text('批准'));
        await tester.pumpAndSettle();
        await settle(tester);

        // 落库为 runtime 绑定并出卡，pending 清空。
        final binding = harness.bindings.byProjectId('com.ghost.newapp');
        expect(binding, isNotNull);
        expect(binding!.origin, BindingOrigin.runtime);
        expect(harness.pending.has('com.ghost.newapp'), isFalse);
        expect(find.text('待批准'), findsNothing);
        expect(find.text('运行时发现'), findsOneWidget);
        expect(find.textContaining('已批准关联：新应用'), findsOneWidget);
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('无 entry 的批准对话框注明仅观察与回收（决策点1）', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create();
      try {
        harness.enableDiscovery();
        harness.pending.record(
          projectId: 'com.ghost.noentry',
          projectName: '无入口应用',
          services: [
            ServiceDeclaration(id: 'svc', name: '服务', methods: ['status']),
          ],
        );

        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.tap(find.text('批准…'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('该应用未自报入口：启动器将不能拉起该应用，仅可观察与回收。'),
          findsOneWidget,
        );

        await tester.tap(find.text('批准'));
        await tester.pumpAndSettle();
        await settle(tester);

        final binding = harness.bindings.byProjectId('com.ghost.noentry');
        expect(binding, isNotNull);
        expect(binding!.learnedEntry, isNull);
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('忽略：入忽略列表、卡片消失、可在设置页恢复', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create();
      try {
        harness.enableDiscovery();
        harness.pending.record(
          projectId: 'com.ghost.ignored',
          projectName: '被忽略的应用',
        );

        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('被忽略的应用'), findsOneWidget);

        await tester.tap(find.text('忽略'));
        await tester.pumpAndSettle();
        await settle(tester);

        expect(
          harness.preferences.ignoredDiscoveryProjects,
          contains('com.ghost.ignored'),
        );
        expect(harness.pending.has('com.ghost.ignored'), isFalse);
        expect(find.text('被忽略的应用'), findsNothing);
        expect(find.textContaining('可在设置中恢复'), findsOneWidget);

        // 设置页恢复：移除后下次连接重新出现在待批准。
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsPage(
              preferences: harness.preferences,
              onCheckNow: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('运行时发现'), findsOneWidget);
        expect(find.text('com.ghost.ignored'), findsOneWidget);

        await tester.tap(find.text('恢复'));
        await tester.pumpAndSettle();
        await settle(tester);
        expect(
          harness.preferences.ignoredDiscoveryProjects,
          isNot(contains('com.ghost.ignored')),
        );
        expect(find.text('com.ghost.ignored'), findsNothing);
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('runtime 卡片带「运行时发现」标记，隐藏刷新配置入口', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create();
      try {
        await harness.bindings.insert(
          ProjectBinding(
            projectId: 'com.ghost.runtime',
            name: '运行时应用',
            services: const [ManifestService(id: 'svc', name: '服务')],
            boundAt: DateTime(2026, 10, 7),
            origin: BindingOrigin.runtime,
            learnedEntry: SdkEntry.executable('/usr/local/bin/runtime-app'),
          ),
        );

        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text('运行时应用'), findsOneWidget);
        expect(find.text('运行时发现'), findsOneWidget);
        // config 卡片仍有刷新配置，runtime 卡片没有。
        expect(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '刷新配置'),
          findsOneWidget,
        );
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('learned entry 路径消失：卡片显示「入口失效」与自愈引导', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create();
      try {
        await harness.bindings.insert(
          ProjectBinding(
            projectId: 'com.ghost.gone',
            name: '入口没了的应用',
            services: const [ManifestService(id: 'svc', name: '服务')],
            boundAt: DateTime(2026, 10, 7),
            origin: BindingOrigin.runtime,
            learnedEntry: SdkEntry.executable(
              '${harness.directory.path}/does-not-exist/tool',
            ),
          ),
        );

        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.textContaining('入口失效：'), findsOneWidget);
        expect(find.textContaining('重新运行该应用即可自动修复。'), findsOneWidget);
      } finally {
        await harness.dispose();
      }
    });
  });
}
