import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maclauncher/project_card.dart';

import 'launcher_test_harness.dart';

void main() {
  testWidgets('management and settings content follow the window width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'service-with-a-long-id': '用于检查窗口缩放的服务'},
      );
      try {
        await tester.pumpWidget(harness.app());
        var previousCardWidth = 0.0;
        var previousInset = 0.0;
        for (final width in [480.0, 800.0, 1440.0]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pump();
          final card = tester.getRect(find.byType(ProjectCard));
          expect(card.width, greaterThan(previousCardWidth));
          expect(card.left, greaterThanOrEqualTo(previousInset));
          expect(card.left, lessThan(width * 0.05));
          expect(width - card.right, closeTo(card.left, 0.1));
          for (final label in ['启动', '回收', '刷新', '日志', '登录启动']) {
            final action = tester.getRect(find.text(label));
            expect(action.left, greaterThanOrEqualTo(card.left));
            expect(action.right, lessThanOrEqualTo(card.right));
          }
          expect(tester.takeException(), isNull);
          previousCardWidth = card.width;
          previousInset = card.left;
        }

        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        var previousRowWidth = 0.0;
        for (final width in [480.0, 800.0, 1440.0]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pump();
          final row = tester.getRect(
            find.byKey(const ValueKey('update-check-on-launch')),
          );
          expect(row.width, greaterThan(previousRowWidth));
          expect(row.left, lessThan(width * 0.1));
          expect(width - row.right, closeTo(row.left, 0.1));
          expect(tester.takeException(), isNull);
          previousRowWidth = row.width;
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await harness.dispose();
      }
    });
  });
}
