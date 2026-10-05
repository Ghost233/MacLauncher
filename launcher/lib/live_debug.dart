import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Debug-only live inspection bridges so an external probe can capture the
/// current window as PNG and dump the widget/render trees over the VM
/// service. Registered only in debug builds; absent from release.
void registerLiveDebugExtensions() {
  if (!kDebugMode) return;

  developer.registerExtension('ext.maclauncher.screenshot', (
    method,
    params,
  ) async {
    try {
      final binding = WidgetsBinding.instance;
      final renderView = binding.renderViews.first;
      // debugLayer is the debug-build accessor for the (protected) root
      // layer; this file only runs in debug mode.
      final layer = renderView.debugLayer;
      if (layer is! OffsetLayer) {
        return developer.ServiceExtensionResponse.error(
          -32000,
          'root layer is ${layer.runtimeType}, not OffsetLayer',
        );
      }
      final image = await layer.toImage(
        renderView.paintBounds,
        pixelRatio: 2.0,
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        return developer.ServiceExtensionResponse.error(-32000, 'no bytes');
      }
      final path = params['path'] ?? '/tmp/maclauncher_shot.png';
      await File(path).writeAsBytes(byteData.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result('{"path": "$path"}');
    } catch (e) {
      return developer.ServiceExtensionResponse.error(-32000, '$e');
    }
  });

  developer.registerExtension('ext.maclauncher.dumpTree', (
    method,
    params,
  ) async {
    try {
      final binding = WidgetsBinding.instance;
      final widgetsPath = params['widgets'] ?? '/tmp/maclauncher_widgets.txt';
      final renderPath = params['render'] ?? '/tmp/maclauncher_render.txt';
      await File(
        widgetsPath,
      ).writeAsString(binding.rootElement?.toStringDeep() ?? 'no root element');
      await File(renderPath)
          .writeAsString(binding.renderViews.first.toStringDeep());
      return developer.ServiceExtensionResponse.result(
        '{"widgets": "$widgetsPath", "render": "$renderPath"}',
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(-32000, '$e');
    }
  });
}
