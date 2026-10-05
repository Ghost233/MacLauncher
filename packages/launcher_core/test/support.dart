import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// Opens a raw client socket to the endpoint.
Future<Socket> connectRaw(String socketPath) => Socket.connect(
  InternetAddress(socketPath, type: InternetAddressType.unix),
  0,
);

/// Sends a hand-crafted hello and returns the welcome message.
Future<Map<String, Object?>> rawHello(
  Socket socket,
  Map<String, Object?> hello,
) async {
  final welcome = decodeMessages(socket).first;
  writeMessage(socket, hello);
  await socket.flush();
  return welcome;
}

Map<String, Object?> helloMessage({
  required String projectId,
  int protocolVersion = kProtocolVersion,
}) => {
  'type': 'hello',
  'protocolVersion': protocolVersion,
  'projectId': projectId,
  'appSessionId': 'raw-session',
  'capabilities': {'services': const [], 'app': const []},
};

/// Waits until [predicate] holds or [timeout] expires.
Future<void> until(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future.delayed(step);
  }
}
